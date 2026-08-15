import AVFoundation
import AppKit
import AudioCore
import Observation
import SwiftUI

/// All app state, and the only place that talks to `AudioCore`.
///
/// v1 deliberately holds a single effect slot rather than a chain. The routing underneath is
/// the hard, verified part; growing one slot into an ordered chain is a change to this type
/// and `AudioEngineController.buildGraph`, not to the device or channel-map logic.
///
/// Every user-visible choice — input device, plugin, the plugin's own dial positions, and
/// whether the engine was running — is mirrored into an immutable `SessionSnapshot` and written
/// to disk, so a relaunch (or a crash caused by an in-process plugin, gotcha #8) resumes rather
/// than restarts.
@MainActor
@Observable
final class AppModel {
    private(set) var inputDevices: [AudioDevice] = []
    private(set) var availablePlugins: [PluginDescriptor] = []
    private(set) var virtualDevice: AudioDevice?
    private(set) var monitorDevice: AudioDevice?

    private(set) var selectedInputUID: String?
    private(set) var selectedPlugin: PluginDescriptor?
    private(set) var loadedEffect: AVAudioUnit?

    private(set) var isRunning = false
    private(set) var isMonitorEnabled = true
    private(set) var status = ""
    private(set) var inputPeak: Float = 0
    private(set) var opensAtLogin = LoginItem.isEnabled

    /// What other apps see in their microphone list. Named for the app rather than for
    /// BlackHole, which is the driver underneath and means nothing to the person choosing it.
    let virtualMicrophoneName = VirtualMicrophone.deviceName

    private let engine = AudioEngineController()
    private let store: SessionStore?
    private var snapshot: SessionSnapshot = .empty
    private var meterTimer: Timer?
    private var autosaveTimer: Timer?
    private var meterTicks = 0
    private let meterHz: Double = 20
    private var hasRestored = false
    private var hasQuit = false

    /// A plugin window has no "save" button — parameters change whenever the user drags a knob.
    /// Capturing on a slow timer bounds what a crash can cost without serializing the plugin's
    /// whole state on every mouse move.
    private static let autosaveInterval: TimeInterval = 30

    init(store: SessionStore? = try? SessionStore.default()) {
        self.store = store

        do {
            snapshot = try store?.load() ?? .empty
        } catch {
            // Keep running with a clean session rather than refusing to launch, but say so —
            // silently reverting to defaults reads as "my settings vanished".
            status = "Saved settings could not be read and were ignored: \(error.localizedDescription)"
        }
        selectedInputUID = snapshot.inputUID
        isMonitorEnabled = snapshot.isMonitorEnabled

        // ⌘Q, logout, and the Quit button all end up here. The aggregate device must be
        // destroyed on *every* exit path or it outlives the process (gotcha #7).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForQuit() }
        }

        scheduleRestore()
    }

    /// Waits for AppKit to finish launching before touching CoreAudio.
    ///
    /// `restore()` ends in a synchronous device call (`AudioDeviceCreateIOProcID`), and making
    /// that call on a main thread whose run loop has not started yet deadlocks against
    /// `coreaudiod`: it blocks in `mach_msg` inside `_TellServerAboutStreamUsage` and never
    /// returns. The app then hangs at launch with no crash, no error, and a menu bar icon that
    /// never responds. It only reproduces once the microphone is actually authorized — a denied
    /// mic needs no negotiation and returns immediately, which is how this hid behind the
    /// permission problem.
    private func scheduleRestore() {
        guard NSApp?.isRunning != true else {
            Task { await restore() }
            return
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.restore() }
            }
        }
    }

    // MARK: - Startup

    /// One-shot startup restore. Deliberately separate from `refresh()`, which runs every time
    /// the menu opens: reinstating a plugin and resuming the engine must happen exactly once.
    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true

        await refresh()

        if let plugin = snapshot.plugin {
            await load(plugin, state: snapshot.pluginState)
        }
        if snapshot.isRunning {
            await start()
        }
    }

    // MARK: - Discovery

    /// Async because every device query is a synchronous round trip to `coreaudiod`, and this
    /// runs on `onAppear` for both the menu and the window. Doing that dozen-call scan on the
    /// main actor made the UI hitch each time either one opened.
    func refresh() async {
        let scan = await Task.detached(priority: .userInitiated) {
            Result { try DeviceDiscovery.scan() }
        }.value

        switch scan {
        case .success(let environment):
            apply(environment)
        case .failure(let error):
            status = "Could not read audio devices: \(error)"
        }

        if availablePlugins.isEmpty {
            await rescanPlugins()
        }

        // A saved device that has since been unplugged falls back to the system default above;
        // record that fallback so the next launch does not keep chasing the missing device.
        if snapshot.inputUID != selectedInputUID {
            update { $0.settingInput(selectedInputUID) }
        }
    }

    private func apply(_ environment: AudioEnvironment) {
        virtualDevice = environment.loopback
        monitorDevice = environment.monitor
        inputDevices = environment.inputs

        // Resolved rather than defaulted: the system default input is regularly BlackHole
        // itself, because pointing other apps at it is what this app is for. That UID is
        // excluded from `inputs` on purpose, and naming it here made `start()` refuse with
        // "No input device selected" and capture nothing.
        selectedInputUID = InputSelection.resolve(
            saved: selectedInputUID,
            available: environment.inputs,
            systemDefault: environment.systemDefaultInputUID
        )

        if virtualDevice == nil {
            status = "BlackHole not found — install it with: brew install blackhole-2ch"
        } else if status.hasPrefix("BlackHole not found") {
            status = ""
        }
    }

    /// Re-reads the installed Audio Units. `refresh()` only scans when the list is empty, so
    /// this is how a plugin installed while the app was running becomes visible. Off the main
    /// actor because enumerating ~700 components is not instant.
    func rescanPlugins() async {
        availablePlugins = await Task.detached(priority: .userInitiated) {
            PluginCatalog.installedEffects()
        }.value
    }

    // MARK: - Input slot

    func selectInput(_ uid: String?) async {
        guard uid != selectedInputUID else { return }
        selectedInputUID = uid
        update { $0.settingInput(uid) }
        // Switching devices means rebuilding the aggregate, so the engine is cycled rather
        // than reconfigured in place.
        await restartIfRunning()
    }

    // MARK: - Monitoring

    /// Turns the speakers/headphones leg of the output on or off.
    ///
    /// The virtual microphone is unaffected either way — other apps keep receiving the processed
    /// signal. This exists because monitoring through *speakers* puts the processed output back
    /// in front of the microphone, and that loop is what makes a live compressor howl.
    func setMonitorEnabled(_ enabled: Bool) async {
        guard enabled != isMonitorEnabled else { return }
        isMonitorEnabled = enabled
        update { $0.settingMonitorEnabled(enabled) }
        await restartIfRunning()
    }

    // MARK: - Plugin slot

    func selectPlugin(_ descriptor: PluginDescriptor?) async {
        EngineLog.logger.info("effect selected: \(descriptor?.name ?? "none", privacy: .public)")
        // Drops any saved state along with the outgoing plugin — a state blob is only
        // meaningful to the plugin that produced it.
        update { $0.settingPlugin(descriptor) }

        guard let descriptor else {
            unload()
            await restartIfRunning()
            return
        }

        await load(descriptor, state: nil)
        await restartIfRunning()
    }

    private func load(_ descriptor: PluginDescriptor, state: Data?) async {
        do {
            let unit = try await PluginCatalog.instantiate(descriptor)
            selectedPlugin = descriptor
            loadedEffect = unit
            status = ""

            if let state {
                do {
                    try PluginState.apply(state, to: unit)
                } catch {
                    // The plugin is loaded and usable; only its saved dial positions were lost.
                    status = "\(descriptor.name) loaded with default settings — its saved "
                        + "settings could not be restored."
                }
            }
            startAutosave()
        } catch {
            unload()
            update { $0.settingPlugin(nil) }
            status = "Could not load \(descriptor.name): \(error.localizedDescription)"
        }
    }

    private func unload() {
        stopAutosave()
        loadedEffect = nil
        selectedPlugin = nil
    }

    /// Changing the graph requires a stop/start cycle. That costs a brief dropout, which is a
    /// better trade than the fragility of rewiring a running AVAudioEngine.
    private func restartIfRunning() async {
        guard isRunning else { return }
        await stop()
        await start()
    }

    // MARK: - Transport

    func toggle() async {
        if isRunning {
            await stop()
        } else {
            await start()
        }
    }

    /// Async because `engine.start()` is: the device work happens on the engine's own queue so
    /// the main actor stays responsive while CoreAudio negotiates with coreaudiod. See the
    /// isolation note on `AudioEngineController`.
    func start() async {
        guard let inputUID = selectedInputUID,
              let input = inputDevices.first(where: { $0.uid == inputUID })
        else {
            // `InputSelection.resolve` guarantees the selection is one of `inputDevices`, so
            // reaching here means the list itself is empty rather than the choice being stale.
            status = inputDevices.isEmpty
                ? "No microphone available. Connect one, or check Privacy & Security > Microphone."
                : "No input device selected"
            return
        }
        guard let virtualDevice else {
            status = "BlackHole not found — install it with: brew install blackhole-2ch"
            return
        }
        guard let monitorDevice else {
            status = "No output device available"
            return
        }
        // Monitoring into either the loopback or our own published device would feed the
        // processed signal back into itself. The second case only became possible once the
        // aggregate went public, and it is easy to hit by accident: "PlugInput" now appears in
        // the system's output list too.
        guard monitorDevice.uid != virtualDevice.uid,
              monitorDevice.uid != VirtualMicrophone.deviceUID
        else {
            let reason = "System output is set to \(monitorDevice.name). "
                + "Switch it to your speakers or headphones."
            status = reason
            EngineLog.logger.error("engine start refused: \(reason, privacy: .public)")
            return
        }

        EngineLog.logger.info(
            """
            starting: input \(input.name, privacy: .public), \
            monitor \(monitorDevice.name, privacy: .public), \
            virtual \(virtualDevice.name, privacy: .public)
            """
        )

        do {
            try await engine.start(
                input: input,
                monitor: monitorDevice,
                virtual: virtualDevice,
                effect: .init(loadedEffect),
                isMonitorEnabled: isMonitorEnabled
            )
            isRunning = true
            update { $0.settingRunning(true) }
            status = "Running — select \(virtualDevice.name) as the microphone in your other app"
            startMetering()
        } catch {
            isRunning = false
            // Clear the resume flag, or a start that fails on every launch keeps retrying it.
            update { $0.settingRunning(false) }
            let reason = "\(error)"
            status = reason
            EngineLog.logger.error("engine start failed: \(reason, privacy: .public)")
        }
    }

    func stop() async {
        stopMetering()
        await engine.stopAsync()
        isRunning = false
        inputPeak = 0
        persistSession { $0.settingRunning(false) }
        if !status.hasPrefix("Could not") { status = "" }
    }

    /// Final save and teardown, idempotent because both the Quit button and `willTerminate`
    /// reach it. Leaves `isRunning` in the snapshot untouched, so quitting while running means
    /// the next launch comes back up running.
    func prepareForQuit() {
        guard !hasQuit else { return }
        hasQuit = true

        persistSession()
        stopMetering()
        stopAutosave()
        // Destroys the aggregate, which is now a *visible* device — an orphan would sit in every
        // app's microphone list advertising a mic that produces nothing (gotcha #7).
        engine.stop()
        isRunning = false
    }

    var effectLatencyMilliseconds: Double {
        engine.effectLatencySeconds * 1000
    }

    // MARK: - Login item

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            status = "Could not \(enabled ? "enable" : "disable") Open at Login: "
                + error.localizedDescription
        }
        // Read the real state back rather than assuming the request took effect: registration
        // fails for a bundle macOS cannot resolve, and the toggle must not lie about it.
        opensAtLogin = LoginItem.isEnabled
    }

    // MARK: - Persistence

    private func update(_ transform: (SessionSnapshot) -> SessionSnapshot) {
        snapshot = transform(snapshot)

        guard let store else { return }
        do {
            try store.save(snapshot)
        } catch {
            status = "Settings could not be saved: \(error.localizedDescription)"
        }
    }

    /// Writes the session out with the plugin's *live* settings folded in.
    private func persistSession(_ transform: (SessionSnapshot) -> SessionSnapshot = { $0 }) {
        update { transform($0.settingPluginState(capturedPluginState())) }
    }

    private func capturedPluginState() -> Data? {
        guard let loadedEffect, snapshot.plugin != nil else { return snapshot.pluginState }

        do {
            return try PluginState.capture(from: loadedEffect)
        } catch {
            status = "Could not read \(selectedPlugin?.name ?? "the plugin")'s settings: "
                + error.localizedDescription
            return snapshot.pluginState
        }
    }

    // MARK: - Timers

    private func startMetering() {
        meterTicks = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / meterHz, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.inputPeak = self.engine.inputPeak
                self.meterTicks += 1

                // Once a second, so the running app can be observed from a terminal. A silent
                // input reads as an exact 0.0 here, which is the difference between "macOS is
                // feeding us zeros" and "the signal is being lost further down the graph".
                if self.meterTicks % Int(self.meterHz) == 0 {
                    EngineLog.levels.info("input peak \(self.inputPeak, privacy: .public)")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func startAutosave() {
        guard autosaveTimer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.persistSession() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    private func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }
}
