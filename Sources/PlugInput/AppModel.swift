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

    /// Which of the selected device's channels carries the microphone, zero-based.
    ///
    /// Only meaningful on interfaces with more than one input. Defaulting to 0 keeps a built-in
    /// mic — and every existing saved session — behaving exactly as before, while giving anyone
    /// whose mic is on input 2 a way to say so. Without it they got exact digital silence and a
    /// message blaming microphone permissions.
    private(set) var selectedInputChannel = 0

    /// Channels worth offering for the current input device; empty when there is no choice.
    var selectableInputChannels: [Int] {
        guard let device = selectedInputDevice, device.inputChannels > 1 else { return [] }
        return Array(0..<device.inputChannels)
    }

    var selectedInputDevice: AudioDevice? {
        inputDevices.first { $0.uid == selectedInputUID }
    }

    /// The ordered effect chain, as an immutable value. Every edit computes a new one and
    /// persists it, so a failed rebuild cannot leave the saved chain half-changed.
    private(set) var chain: PluginChain = .empty

    /// The live Audio Units, keyed by the slot that owns each one.
    ///
    /// Kept beside the chain rather than inside it: `PluginChain` is a `Sendable` value that gets
    /// written to disk, and an `AVAudioUnit` is neither of those things. The slot id is what ties
    /// the two together — which is also why slots carry an id rather than being addressed by
    /// index, since a reorder would otherwise repoint every unit at its neighbour.
    private(set) var loadedUnits: [UUID: AVAudioUnit] = [:]

    /// The chain's units in signal order, skipping any slot whose plugin failed to load.
    var orderedUnits: [AVAudioUnit] {
        chain.slots.compactMap { loadedUnits[$0.id] }
    }

    private(set) var isRunning = false

    /// True when the system's default input is PlugInput's own loopback driver.
    ///
    /// macOS elects a newly appeared device as the default input, and installing the driver
    /// restarts `coreaudiod`, which is exactly that trigger. Every app that follows the system
    /// default — Zoom, Discord, a DAW — then listens to a loopback carrying silence unless
    /// PlugInput happens to be running and routing into it. Worth saying out loud, because from
    /// the user's side this presents as "my microphone stopped working", with nothing pointing
    /// at the app that caused it.
    private(set) var isDefaultInputHijacked = false

    private(set) var isMonitorEnabled = true
    private(set) var status = ""
    private(set) var inputPeak: Float = 0
    private(set) var opensAtLogin = LoginItem.isEnabled

    /// What other apps see in their microphone list. The name is the HAL driver's own, so it
    /// reads as "PlugInput" rather than as someone else's driver.
    let virtualMicrophoneName = VirtualMicrophone.deviceName

    /// Said in two places — when a scan finds no loopback, and when a start is refused for the
    /// same reason — and compared against in order to clear itself, so it lives in one place.
    ///
    /// Phrased for someone who installed a `.pkg` and has no repository checkout. It used to
    /// read "install it with ./make-driver.sh", which is a build instruction: correct for the
    /// one machine this was written on and meaningless to everybody else.
    private static let driverMissingStatus =
        "PlugInput audio driver not found — reinstall PlugInput to restore it"

    /// Open plugin interfaces, owned here rather than by a view.
    ///
    /// Each of three views used to hold its own `@State` controller, so two of them tracked
    /// nothing and the third died with the console window — stranding any plugin windows it had
    /// opened on screen, unreachable, while a fresh controller happily opened a *second* window
    /// for the same slot. Owning them alongside the units they display is what lets `removeSlot`
    /// and `prepareForQuit` guarantee an interface never outlives its `AVAudioUnit`.
    let pluginWindows = PluginWindowController()

    private let engine = AudioEngineController()

    /// Watches for the main thread going unresponsive and logs it. Reports only — see
    /// `MainThreadWatchdog` for why nothing tries to intervene.
    private let watchdog = MainThreadWatchdog()
    private let store: SessionStore?
    private var snapshot: SessionSnapshot = .empty
    private var meterTimer: Timer?
    private var autosaveTimer: Timer?
    private var meterTicks = 0
    private let meterHz: Double = 20
    private var hasRestored = false
    private var hasQuit = false

    /// The tail of the transport chain: every start, stop and restart waits on the one before it.
    ///
    /// `@MainActor` orders statements but not *tasks* across suspension points, and every route
    /// into transport goes through `await` — `toggle`, `selectInput`, `setMonitorEnabled`, and
    /// each chain edit. Two overlapping starts would each call `startMetering()`, and the second
    /// would overwrite `meterTimer` while the first kept firing forever against a strongly
    /// captured `self`.
    ///
    /// This used to be a `isTransportBusy` flag that made an overlapping call **return without
    /// doing anything**, which prevented the overlap by discarding the request. Clicking ↑ twice
    /// in quick succession, or removing a slot while the previous edit's restart was still in
    /// flight, therefore left the engine running the *previous* chain while the editor showed
    /// the new one — audible order silently disagreeing with displayed order, which is the exact
    /// class of failure this app exists to avoid. Queueing costs an extra engine cycle and keeps
    /// the two in step.
    private var transportTail: Task<Void, Never>?

    /// A plugin window has no "save" button — parameters change whenever the user drags a knob.
    /// Capturing on a slow timer bounds what a crash can cost without serializing the plugin's
    /// whole state on every mouse move.
    private static let autosaveInterval: TimeInterval = 30

    /// Past this, a state capture is a hitch the user can feel rather than a background cost,
    /// and the log says so at error level with the responsible plugin named.
    private static let slowStateCaptureMilliseconds = 100

    /// `store` is injectable for testing; `nil` means "open the default location", which is what
    /// the app does.
    ///
    /// The open happens here rather than in a default argument. It used to read
    /// `store: SessionStore? = try? SessionStore.default()`, which threw the reason away — and a
    /// nil store turns every later save into a silent no-op, so a user whose Application Support
    /// directory cannot be written lost every setting on every launch, forever, with nothing
    /// said about why.
    init(store: SessionStore? = nil) {
        var openFailure: String?
        if let store {
            self.store = store
        } else {
            do {
                self.store = try SessionStore.default()
            } catch {
                self.store = nil
                openFailure = "Settings cannot be saved — \(error.localizedDescription). "
                    + "PlugInput will still run, but nothing will be remembered between launches."
            }
        }

        do {
            snapshot = try self.store?.load() ?? .empty
        } catch {
            // Keep running with a clean session rather than refusing to launch, but say so —
            // silently reverting to defaults reads as "my settings vanished".
            status = "Saved settings could not be read and were ignored: \(error.localizedDescription)"
        }
        // An unopenable store is the more serious of the two failures — it is permanent rather
        // than one-off — so it wins the single status slot.
        if let openFailure { status = openFailure }

        selectedInputUID = snapshot.inputUID
        selectedInputChannel = snapshot.inputChannel
        isMonitorEnabled = snapshot.isMonitorEnabled
        // Shown immediately, before the units behind it exist — `restore()` instantiates those
        // asynchronously, and a chain that appeared one plugin at a time would read as data loss.
        chain = snapshot.chain

        // ⌘Q, logout, and the Quit button all end up here. The aggregate device must be
        // destroyed on *every* exit path or it outlives the process (gotcha #7).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForQuit() }
        }

        // The engine stops itself when the devices under it change. Without this the UI would go
        // on claiming "Running" against a graph that no longer exists.
        engine.onUnexpectedStop { [weak self] reason in
            Task { @MainActor in self?.handleUnexpectedStop(reason) }
        }

        // Started before anything else can block: a stall during the restore that follows is
        // exactly the kind this is for, and `restore()` is where third-party plugins first load.
        watchdog.start()

        scheduleRestore()
    }

    /// The engine stopped on its own — an interface unplugged, a device reconfigured.
    private func handleUnexpectedStop(_ reason: String) {
        guard isRunning else { return }

        stopMetering()
        isRunning = false
        inputPeak = 0
        status = reason
        // Deliberately not resumed on the next launch. A device that vanished mid-session is
        // likelier to still be missing than to be back, and a resume that fails on every launch
        // is a worse experience than a Start button pressed once.
        update { $0.settingRunning(false) }
        // The device list has changed by definition, so re-read it rather than leaving stale
        // names sitting next to a stopped engine.
        Task { await refresh() }
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

        // First line of every transcript, so a log excerpt says which build produced it. Every
        // question this app gets asked is answered from its log, and until now none of those
        // logs said whether the reporter was running the build that fixed the thing they are
        // reporting.
        EngineLog.logger.info("PlugInput \(AppVersion.current.description, privacy: .public) starting")

        await refresh()

        await loadChain(snapshot.chain)

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
        // Records a channel that `apply` had to clamp, for the same reason: chasing a setting
        // that can no longer apply is how a saved session keeps breaking every launch.
        if snapshot.inputChannel != selectedInputChannel {
            update { $0.settingInputChannel(selectedInputChannel) }
        }
    }

    private func apply(_ environment: AudioEnvironment) {
        virtualDevice = environment.loopback
        monitorDevice = environment.monitor
        inputDevices = environment.inputs

        // Resolved rather than defaulted: the system default input is regularly the loopback
        // itself, because pointing other apps at it is what this app is for. That UID is
        // excluded from `inputs` on purpose, and naming it here made `start()` refuse with
        // "No input device selected" and capture nothing.
        selectedInputUID = InputSelection.resolve(
            saved: selectedInputUID,
            available: environment.inputs,
            systemDefault: environment.systemDefaultInputUID
        )

        isDefaultInputHijacked = environment.systemDefaultInputUID == VirtualMicrophone.driverUID

        // A saved channel can outlive the device it was chosen on — the interface gets unplugged
        // and the fallback is a one-channel built-in mic. Clamping here stops `start()` refusing
        // with "channel 5 does not exist" over a choice the user can no longer even see.
        if selectedInputChannel >= (selectedInputDevice?.inputChannels ?? 1) {
            selectedInputChannel = 0
        }

        if virtualDevice == nil {
            status = Self.driverMissingStatus
        } else if status == Self.driverMissingStatus {
            status = ""
        }
    }

    /// Points the system default input back at a real microphone.
    ///
    /// Only ever called from the warning this app shows about `isDefaultInputHijacked`, because
    /// the default input is a system-wide setting and changing it uninvited is the same class of
    /// rudeness the warning exists to complain about.
    func restoreDefaultInput() async {
        guard let device = selectedInputDevice ?? inputDevices.first else {
            status = "No microphone available to set as the system default."
            return
        }

        do {
            try DeviceEnumerator.setDefaultInputDevice(device.id)
            EngineLog.logger.info(
                "system default input set back to \(device.name, privacy: .public)"
            )
            // Read it back rather than assuming the write took — the recurring lesson of
            // gotcha #5, and the flag the warning is drawn from must not go stale.
            await refresh()
            if !isDefaultInputHijacked {
                status = "System default input set to \(device.name)."
            }
        } catch {
            status = "Could not change the system default input: \(error.localizedDescription)"
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
        // Back to the first channel: an index only means something on the device it was picked
        // on, and carrying "channel 4" onto a mono built-in mic would refuse every start.
        // `SessionSnapshot.settingInput` enforces the same rule on the persisted side.
        selectedInputChannel = 0
        update { $0.settingInput(uid) }
        // Switching devices means rebuilding the aggregate, so the engine is cycled rather
        // than reconfigured in place.
        await restartIfRunning()
    }

    /// Picks which of a multi-input interface's channels carries the microphone.
    ///
    /// Zero-based here; the UI shows it one-based, because interfaces label their inputs
    /// starting at 1 and a picker disagreeing with the silkscreen is its own bug report.
    func selectInputChannel(_ channel: Int) async {
        guard channel != selectedInputChannel,
              selectableInputChannels.contains(channel)
        else { return }

        selectedInputChannel = channel
        update { $0.settingInputChannel(channel) }
        // The channel map is applied during start, so this is a rebuild like any other.
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

    // MARK: - Chain

    /// Appends an effect to the end of the chain.
    ///
    /// The unit is instantiated *before* the new chain is adopted, so a plugin that fails to load
    /// leaves both the chain and the engine exactly as they were rather than adding an empty slot
    /// the graph would silently skip.
    func addPlugin(_ descriptor: PluginDescriptor) async {
        let grown = chain.adding(descriptor)
        guard grown != chain, let slot = grown.slots.last else {
            status = "Chain is full — \(PluginChain.maximumSlots) effects is the limit."
            return
        }

        EngineLog.logger.info("chain: added \(descriptor.name, privacy: .public)")
        guard await instantiate(slot) else { return }
        apply(grown)
        await restartIfRunning()
    }

    func removeSlot(_ id: UUID) async {
        guard let slot = chain.slot(id) else { return }
        EngineLog.logger.info("chain: removed \(slot.plugin.name, privacy: .public)")

        // Before the unit goes: a vendor view controller left holding a detached unit is a
        // crash waiting for the next redraw.
        pluginWindows.close(id)
        loadedUnits[id] = nil
        apply(chain.removing(id))
        if chain.isEmpty { stopAutosave() }
        await restartIfRunning()
    }

    /// Moves a slot by one position. A no-op move never touches the engine — the buttons at the
    /// ends of the chain are disabled, but a dropout for a reorder that did not happen would be
    /// a poor way to find that out.
    func moveSlot(_ id: UUID, by offset: Int) async {
        let reordered = chain.moving(id, by: offset)
        guard reordered != chain else { return }

        let order = reordered.slots.map(\.plugin.name).joined(separator: " → ")
        EngineLog.logger.info("chain: reordered to \(order, privacy: .public)")
        apply(reordered)
        await restartIfRunning()
    }

    /// The one chain edit that does not rebuild the graph.
    ///
    /// Bypass maps onto `shouldBypassEffect` on the unit itself, which is live — so unlike add,
    /// remove and reorder, this costs no dropout. That is what makes it usable for actually
    /// comparing a plugin in and out while talking.
    func setBypass(_ isBypassed: Bool, for id: UUID) {
        loadedUnits[id]?.auAudioUnit.shouldBypassEffect = isBypassed
        apply(chain.settingBypass(isBypassed, for: id))
    }

    /// Adopts a new chain and writes it out. Never partially applied: the value is computed
    /// first, then stored and persisted together.
    private func apply(_ newChain: PluginChain) {
        chain = newChain
        update { $0.settingChain(newChain) }
    }

    /// Brings a saved chain back to life, in order.
    ///
    /// Slots whose plugin no longer instantiates — uninstalled since last launch, or a vendor
    /// update that broke it — are dropped from the chain rather than kept as gaps. Keeping them
    /// would mean a chain that reads as four effects while three are audible, which is exactly
    /// the kind of silent discrepancy this app is built to avoid.
    private func loadChain(_ saved: PluginChain) async {
        var loaded: [PluginSlot] = []
        for slot in saved.slots where await instantiate(slot) {
            loaded.append(slot)
        }

        let restored = PluginChain(slots: loaded)
        if restored != saved {
            EngineLog.logger.error(
                "chain: \(saved.slots.count - loaded.count, privacy: .public) saved effect(s) could not be loaded and were dropped"
            )
        }
        apply(restored)
    }

    /// Instantiates one slot's plugin and files the unit under that slot's id.
    ///
    /// Both halves are timed for the same reason `capturedStates` is: they are calls into vendor
    /// code with no bound on how long they take, and a user who sees the app hang while adding a
    /// plugin — or for the whole of a launch that restores a saved chain — has no way to tell
    /// which plugin did it. `instantiate` runs off the main actor; `PluginState.apply` does not,
    /// and setting `fullState` is the same unbounded vendor call as reading it.
    @discardableResult
    private func instantiate(_ slot: PluginSlot) async -> Bool {
        let clock = ContinuousClock()
        let startedLoad = clock.now

        do {
            let unit = try await PluginCatalog.instantiate(slot.plugin)
            let loadMilliseconds = Self.milliseconds(since: startedLoad, on: clock)
            var applyMilliseconds = 0

            if let state = slot.state {
                let startedApply = clock.now
                do {
                    try PluginState.apply(state, to: unit)
                } catch {
                    // The plugin is loaded and usable; only its saved dial positions were lost.
                    status = "\(slot.plugin.name) loaded with default settings — its saved "
                        + "settings could not be restored."
                }
                applyMilliseconds = Self.milliseconds(since: startedApply, on: clock)
            }

            unit.auAudioUnit.shouldBypassEffect = slot.isBypassed

            EngineLog.logger.info(
                "loaded \(slot.plugin.name, privacy: .public) in \(loadMilliseconds, privacy: .public)ms, state applied in \(applyMilliseconds, privacy: .public)ms on the main thread"
            )

            loadedUnits[slot.id] = unit
            startAutosave()
            return true
        } catch {
            status = "Could not load \(slot.plugin.name): \(error.localizedDescription)"
            return false
        }
    }

    /// Changing the graph requires a stop/start cycle. That costs a brief dropout, which is a
    /// better trade than the fragility of rewiring a running AVAudioEngine.
    private func restartIfRunning() async {
        // One queued unit, not `await stop()` followed by `await start()`. As two, another edit
        // could slot its own cycle between them and leave the engine stopped or a cycle behind.
        // `isRunning` is read inside, when the work runs, not when it was submitted.
        await serialized {
            guard self.isRunning else { return }
            await self.performStop()
            await self.performStart()
        }
    }

    // MARK: - Transport

    /// Runs transport work after everything already queued, and never before.
    ///
    /// The body re-reads `isRunning`, `chain` and `orderedUnits` when it actually runs rather
    /// than when it was submitted, so a request queued behind a restart acts on the state that
    /// restart left behind.
    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let predecessor = transportTail
        let task = Task { @MainActor in
            await predecessor?.value
            await work()
        }
        transportTail = task
        await task.value
    }

    func toggle() async {
        await serialized {
            if self.isRunning {
                await self.performStop()
            } else {
                await self.performStart()
            }
        }
    }

    /// Async because `engine.start()` is: the device work happens on the engine's own queue so
    /// the main actor stays responsive while CoreAudio negotiates with coreaudiod. See the
    /// isolation note on `AudioEngineController`.
    func start() async {
        await serialized { await self.performStart() }
    }

    private func performStart() async {
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
            status = Self.driverMissingStatus
            return
        }
        // Resolved to one value, because `nil` is how the engine is told to run without a
        // monitoring leg — and that is not merely a muted channel pair: the output device is
        // then left out of the aggregate entirely, so PlugInput does not open the user's
        // interface at all. See `AudioEngineController.orderedSubDevices`.
        //
        // Everything below is therefore checked only when monitoring is actually on. The
        // absence of an output device used to refuse the start outright, which made a headless
        // Mac — or one transient CoreAudio hiccup in the default-output read — unable to run
        // the virtual microphone, for a device the user had explicitly switched off.
        let monitor: AudioDevice?
        if isMonitorEnabled {
            guard let monitorDevice else {
                status = "No output device available for monitoring. Turn Monitor off to run "
                    + "without one."
                return
            }
            // Monitoring into either the loopback or our own aggregate would feed the processed
            // signal back into itself.
            guard monitorDevice.uid != virtualDevice.uid,
                  monitorDevice.uid != VirtualMicrophone.aggregateUID
            else {
                let reason = "System output is set to \(monitorDevice.name). "
                    + "Switch it to your speakers or headphones, or turn Monitor off."
                status = reason
                EngineLog.logger.error("engine start refused: \(reason, privacy: .public)")
                return
            }
            monitor = monitorDevice
        } else {
            monitor = nil
        }

        EngineLog.logger.info(
            """
            starting: input \(input.name, privacy: .public) \
            ch\(self.selectedInputChannel + 1, privacy: .public), \
            monitor \(monitor?.name ?? "off", privacy: .public), \
            virtual \(virtualDevice.name, privacy: .public)
            """
        )

        do {
            try await engine.start(
                input: input,
                monitor: monitor,
                virtual: virtualDevice,
                effects: .init(orderedUnits),
                inputChannel: selectedInputChannel
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
        await serialized { await self.performStop() }
    }

    private func performStop() async {
        stopMetering()
        await engine.stopAsync()
        isRunning = false
        inputPeak = 0
        // `update`, not `persistSession`. Capturing every loaded plugin's `fullState` is a
        // main-thread call into vendor code with no bound on how long it takes — Nectar 4 and
        // the UAD units are seconds each — and this runs inside `restartIfRunning`, so it was
        // being paid on **every add, remove, reorder and device change**. That is precisely the
        // freeze people report when switching plugins. Nothing is lost by dropping it: the
        // 30-second autosave covers a running session and `prepareForQuit` captures on the way
        // out, which are the two moments the state actually has to be on disk.
        update { $0.settingRunning(false) }
        if !status.hasPrefix("Could not") { status = "" }
    }

    /// Final save and teardown, idempotent because both the Quit button and `willTerminate`
    /// reach it. Leaves `isRunning` in the snapshot untouched, so quitting while running means
    /// the next launch comes back up running.
    ///
    /// **The order is the point.** Teardown runs before the save, not after. macOS gives a
    /// terminating app a bounded window before killing it outright, and `persistSession()`
    /// spends that budget asking up to eight third-party plugins to serialise their entire
    /// state on the main thread — vendors that archive sample banks or impulse responses are
    /// not quick about it. With the save first, one slow plugin meant the process died before
    /// the aggregate was destroyed, leaving exactly the orphan gotcha #7 is about, which then
    /// blocks the next launch's start (gotcha #20). A few seconds of lost knob positions is by
    /// far the cheaper failure, so it goes last.
    ///
    /// Plugin windows close before the units behind them are torn down: a vendor's view
    /// controller outliving the `AVAudioUnit` that owns it is a well-known AU-host crash on exit.
    ///
    /// **It ends in `_exit`, deliberately.** Everything the app owns is safely down by that
    /// point — aggregate destroyed, session written — and what remains is other people's
    /// exit-time code. SSL Native Vocalstrip 2 segfaults on a null `pthread_mutex_lock` from its
    /// own `JUCE v8.0.10: Timer` thread, *seconds after* this method returns, while the process
    /// is running static destructors and tearing down JUCE's globals underneath a timer thread
    /// that is still ticking. Nothing in this app is on that stack and nothing in this app can
    /// order those two events; the plugin loads in-process (gotcha #8), so it takes the host
    /// with it and macOS shows the user a crash dialog for an app that had already finished
    /// quitting correctly.
    ///
    /// `_exit` closes the window that race needs by not opening it: the kernel tears the process
    /// down immediately, with no atexit handlers and no static destructors, so no vendor gets an
    /// exit-time turn. It is the same reasoning as gotcha #29's decision not to dispose units at
    /// termination, carried to the end of the process — and it generalises past this one plugin,
    /// which matters when the crash reports come from users whose plugins nobody here owns.
    ///
    /// What it costs: anything that would otherwise be flushed at exit. This app's own state is
    /// already written by `persistSession` above; the one framework-owned thing worth forcing is
    /// user defaults, where SwiftUI keeps the console window's frame. `exit` rather than `_exit`
    /// would not do — running atexit handlers is precisely what crashes.
    func prepareForQuit() {
        guard !hasQuit else { return }
        hasQuit = true

        stopMetering()
        stopAutosave()
        // Before teardown, not after. `stopForTermination` blocks the main thread for up to two
        // seconds by design, and a watchdog still running would report that as a freeze.
        watchdog.stop()
        pluginWindows.closeAll()
        engine.stopForTermination()
        isRunning = false
        persistSession()

        EngineLog.logger.info("quit: teardown complete, exiting before plugin static teardown")
        UserDefaults.standard.synchronize()
        _exit(EXIT_SUCCESS)
    }

    var effectLatencyMilliseconds: Double {
        engine.effectLatencySeconds * 1000
    }

    /// What to suggest when the engine is running and the meter reads exactly zero.
    ///
    /// A microphone macOS has not authorized returns silence rather than an error (gotcha #11),
    /// so permissions are always worth naming. But this used to assert them as *the* explanation
    /// — "macOS may not have granted microphone access" — without having checked, and on a
    /// multi-input interface the likelier cause by far is that the microphone is in a different
    /// socket than the channel being captured. Sending someone to System Settings to re-grant a
    /// permission they already have is a long way from the actual problem.
    var noSignalHint: String {
        guard let device = selectedInputDevice, device.inputChannels > 1 else {
            return "No signal. If this persists, macOS may not have granted microphone access."
        }
        return "No signal on channel \(selectedInputChannel + 1) of \(device.name). "
            + "Check the microphone is in that input, or pick another channel. If it persists, "
            + "check Privacy & Security > Microphone."
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

    /// Writes the session out with every plugin's *live* settings folded in.
    private func persistSession(_ transform: (SessionSnapshot) -> SessionSnapshot = { $0 }) {
        chain = chain.settingStates(capturedStates())
        update { transform($0.settingChain(chain)) }
    }

    /// Reads each loaded unit's current settings. A plugin that refuses keeps whatever was saved
    /// before rather than losing its slot's settings — one uncooperative plugin must not wipe the
    /// rest of the chain.
    ///
    /// **Timed, because this is the app's last unbounded main-thread call into vendor code.**
    /// `fullState` asks a plugin to serialise everything it knows, and how long that takes is
    /// entirely the vendor's business — some archive sample banks or impulse responses. It used
    /// to run inside every chain edit as well, which is what the switching-plugins freeze was
    /// (gotcha #32); what remains is the 30-second autosave and `prepareForQuit`, where a slow
    /// vendor spends a termination window the OS has already bounded. There is no safe way to
    /// interrupt a call like that, so the honest response is to measure it and name the plugin
    /// in the log rather than leave the freeze unattributed.
    private func capturedStates() -> [UUID: Data] {
        var states: [UUID: Data] = [:]
        var timings: [String] = []
        let clock = ContinuousClock()
        let startedAll = clock.now

        for slot in chain.slots {
            guard let unit = loadedUnits[slot.id] else { continue }
            let started = clock.now
            do {
                states[slot.id] = try PluginState.capture(from: unit)
            } catch {
                status = "Could not read \(slot.plugin.name)'s settings: "
                    + error.localizedDescription
            }
            timings.append("\(slot.plugin.name) \(Self.milliseconds(since: started, on: clock))ms")
        }

        guard !timings.isEmpty else { return states }

        let total = Self.milliseconds(since: startedAll, on: clock)
        let line = timings.joined(separator: ", ")
        // Past the threshold this is a hitch the user can feel, so it is an error rather than a
        // note — and it names the plugin responsible, which nothing else in the log can.
        if total >= Self.slowStateCaptureMilliseconds {
            EngineLog.logger.error(
                "state capture blocked the main thread for \(total, privacy: .public)ms — \(line, privacy: .public)"
            )
        } else {
            EngineLog.logger.info(
                "state capture \(total, privacy: .public)ms — \(line, privacy: .public)"
            )
        }
        return states
    }

    /// Whole milliseconds elapsed, for logging. Rounded because sub-millisecond precision says
    /// nothing about a call this size and only makes the line harder to scan.
    private static func milliseconds(
        since start: ContinuousClock.Instant,
        on clock: ContinuousClock
    ) -> Int {
        let elapsed = clock.now - start
        return Int((Double(elapsed.components.seconds) * 1000)
            + (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000))
    }

    // MARK: - Timers

    private func startMetering() {
        // Never leave a previous timer running. `meterTimer` used to be overwritten outright,
        // so an overlapping start orphaned a 20 Hz timer that kept firing — and, capturing
        // `self` strongly, kept the whole model alive with it. `stopMetering` could only ever
        // cancel the newest of them. Serialising transport through `serialized` should make an
        // overlap impossible now; this makes it harmless if one ever gets through anyway.
        stopMetering()
        meterTicks = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / meterHz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inputPeak = self.engine.inputPeak
                self.meterTicks += 1

                // Once a second, so the running app can be observed from a terminal. A silent
                // input reads as an exact 0.0 here, which is the difference between "macOS is
                // feeding us zeros" and "the signal is being lost further down the graph".
                if self.meterTicks % Int(self.meterHz) == 0 {
                    EngineLog.levels.info(
                        """
                        input peak \(self.inputPeak, privacy: .public), \
                        output peak \(self.engine.outputPeak, privacy: .public)
                        """
                    )
                    if let ring = self.engine.inputRingStatus {
                        EngineLog.levels.info(
                            """
                            capture ring \(ring.available, privacy: .public) buffered, \
                            \(ring.counts.written, privacy: .public) written, \
                            \(ring.counts.read, privacy: .public) read, \
                            \(ring.counts.dropped, privacy: .public) dropped, \
                            \(ring.counts.starved, privacy: .public) starved
                            """
                        )
                    }
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

        let timer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistSession() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    private func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }
}
