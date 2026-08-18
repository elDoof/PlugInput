import AVFoundation
import CoreAudio
import Foundation

/// Drives mic → optional effect → (headphones + virtual device) over a private aggregate.
///
/// The start sequence here is not arbitrary. Every step is one that Phase 0 proved necessary
/// against real hardware, and several of them fail *silently* if reordered or skipped:
///
/// 1. Build a private aggregate of `[input, virtual, monitor]`, input as clock master.
/// 2. Bind both engine sides to it, then **read the binding back** — setting `CurrentDevice`
///    on one node does not bind the other, and the wrong device still produces plausible audio.
/// 3. Apply the input channel map to isolate the mic. Mandatory: the aggregate also exposes
///    the virtual device's *input* channels, which carry what we just wrote to it. Passing
///    those through closes a feedback loop.
/// 4. Connect the graph at the device's own sample rate, or the mixer silently defaults to
///    44.1kHz and resamples between a 48kHz input and a 48kHz output.
/// 5. Apply the output channel map after `start()` and verify by read-back.
/// **Isolation is load-bearing.** Every CoreAudio and `AVAudioEngine` call below runs on
/// `queue`, never on the main thread. `AudioDeviceCreateIOProcID` is a synchronous round trip
/// to `coreaudiod`, and when the microphone still needs a TCC decision that round trip does not
/// return until the user answers the permission dialog. On the main thread that is a deadlock:
/// coreaudiod waits on TCC, TCC waits on the user, and the user cannot answer because the app
/// is frozen mid-launch with an unresponsive menu bar icon — no crash, no error, nothing in the
/// log past `starting:`. Callers `await start(...)` and the UI stays live throughout.
public final class AudioEngineController: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    /// Serialises the whole engine. `AVAudioEngine` is not thread-safe, and a start must never
    /// interleave with a stop.
    private let queue = DispatchQueue(label: "com.pluginput.engine")

    // Touched only on `queue`.
    private let engine = AVAudioEngine()
    private var aggregate: AggregateDevice?
    /// The chain's units, in signal order. Held so teardown can detach every one of them —
    /// a unit left attached to a stopped engine is a leak the next start inherits.
    private var effectNodes: [AVAudioUnit] = []

    /// Whether a tap is currently installed on the input node's bus 0.
    ///
    /// Tracked separately because a tap's lifetime is **not** the engine's: `AVAudioEngine`
    /// stops itself on some device reconfigurations, and the tap survives that. Keying removal
    /// off `engine.isRunning` therefore leaked the tap, and the next `installTap` raised
    /// `nullptr == Tap()` — an Objective-C exception no Swift `try` can catch, so the process
    /// aborted outright. See the crash note on `installInputTap`.
    private var isTapInstalled = false

    /// Written by the realtime tap, read by the UI; carries its own lock.
    private let peakLevel = PeakLevel()

    /// Values the UI reads, published out from `queue` under a lock.
    ///
    /// The UI must never reach into `queue` to read them: a `queue.sync` from the main thread
    /// while a start is in flight would block on exactly the call this class exists to keep off
    /// the main thread.
    private let publishedLock = NSLock()
    private var publishedState: State = .stopped
    private var publishedEffectLatency: Double = 0

    /// Frames per buffer requested from the aggregate. 128 measured ≈ 2.7 ms in Phase 0.
    public let preferredBufferFrames: UInt32 = 128

    public init() {}

    /// A plugin being handed from the UI to the engine queue.
    ///
    /// `AVAudioUnit` is not `Sendable`, and this crossing is real rather than theoretical: the
    /// unit is created on the main actor, driven by `AVAudioEngine` on its own threads, and
    /// shown in a window by AppKit. The box makes the boundary visible in the signature instead
    /// of hiding it behind an implicit capture — the compiler cannot prove this safe, so the
    /// claim belongs in the open. What makes it hold: the UI only ever hands a unit *over*, and
    /// never mutates one the engine is using.
    public struct Effects: @unchecked Sendable {
        /// In signal order: the input feeds `units[0]`, and the last one feeds the mixer.
        public let units: [AVAudioUnit]

        public init(_ units: [AVAudioUnit]) {
            self.units = units
        }
    }

    /// Carries the start arguments across the one hop onto `queue`.
    private struct StartRequest: @unchecked Sendable {
        let input: AudioDevice
        let monitor: AudioDevice
        let virtual: AudioDevice
        let effects: Effects
        let isMonitorEnabled: Bool
    }

    // MARK: - Lifecycle

    /// Awaiting this keeps the caller's thread — in practice the main thread — free while
    /// CoreAudio negotiates. See the isolation note above; this signature is the fix for it.
    public func start(
        input: AudioDevice,
        monitor: AudioDevice,
        virtual: AudioDevice,
        effects: Effects,
        isMonitorEnabled: Bool = true
    ) async throws {
        let request = StartRequest(
            input: input,
            monitor: monitor,
            virtual: virtual,
            effects: effects,
            isMonitorEnabled: isMonitorEnabled
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.startOnQueue(request)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous on purpose. `AppModel` calls it from `willTerminate`, where there is no
    /// chance to await and the aggregate must still be destroyed before the process exits
    /// (gotcha #7). Blocking the caller is acceptable here precisely because teardown involves
    /// no permission negotiation — the asymmetry with `start` is the whole point.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    /// The same teardown, awaited instead of blocking.
    ///
    /// Use this from the UI. `stop()` blocks until the engine queue is free, and the queue is
    /// not free while a start is waiting on a permission decision — so a plugin switch during
    /// that window would freeze the interface for exactly the reason this class was
    /// restructured to avoid.
    public func stopAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopOnQueue()
                continuation.resume()
            }
        }
    }

    // MARK: - On the engine queue

    private func startOnQueue(_ request: StartRequest) throws {
        let (input, monitor, virtual) = (request.input, request.monitor, request.virtual)
        stopOnQueue()

        let subDevices = Self.orderedSubDevices(input: input, virtual: virtual, monitor: monitor)
        // Private. Publishing this aggregate under the name "PlugInput" so other apps could
        // select it directly was tried and does not work — gotchas #17 and #19. Users select
        // BlackHole.
        let device = try AggregateDevice(
            uid: VirtualMicrophone.deviceUID,
            name: "PlugInput Engine",
            subDevices: subDevices,
            clockSourceUID: input.uid
        )
        aggregate = device

        do {
            try EngineDeviceBinding.bind(deviceID: device.id, on: engine)
            try verifyBinding(to: device.id)
            try? BufferSize.set(preferredBufferFrames, on: device.id)
            try applyInputChannelMap(inputUID: input.uid, layout: device.layout)

            try buildGraph(
                effects: request.effects.units,
                virtual: virtual,
                monitor: monitor,
                layout: device.layout,
                isMonitorEnabled: request.isMonitorEnabled
            )

            publish(state: .running)
        } catch {
            // Never leave an aggregate behind on a failed start — an orphan outlives the
            // process and shows up in the user's audio settings.
            stopOnQueue()
            publish(state: .failed(String(describing: error)))
            throw error
        }
    }

    /// Teardown, and it must reach the end whatever happens on the way.
    ///
    /// Every node call here is barriered with `ignoringObjCException` rather than
    /// `withGraphBarrier`: this runs from `willTerminate`, where there is nobody left to report
    /// an error to, and `aggregate?.destroy()` below is the one step that genuinely cannot be
    /// skipped — an orphan outlives the process and sits in the user's audio settings
    /// (gotcha #7). A raise while detaching a node must not cost the destroy.
    private func stopOnQueue() {
        // Unconditionally, and before the engine check. A tap outlives `isRunning`, so removing
        // it only "while running" strands one behind whenever the engine has already stopped
        // itself — and the next start then aborts the process rather than throwing.
        removeInputTap()
        if engine.isRunning {
            ignoringObjCException("stopping engine") { engine.stop() }
        }
        for node in effectNodes {
            ignoringObjCException("detaching effect") { engine.detach(node) }
        }
        effectNodes = []
        aggregate?.destroy()
        aggregate = nil
        peakLevel.reset()
        publish(state: .stopped)
        publish(effectLatency: 0)
    }

    // MARK: - Readable from any thread

    /// Peak of the most recent input buffer, 0...1.
    public var inputPeak: Float {
        peakLevel.current
    }

    public var state: State {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedState
    }

    /// Latency contributed by the hosted effect, in seconds. Linear-phase EQs and mastering
    /// plugins report large values here and are unusable for live monitoring.
    public var effectLatencySeconds: Double {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedEffectLatency
    }

    private func publish(state: State) {
        publishedLock.lock()
        publishedState = state
        publishedLock.unlock()
    }

    private func publish(effectLatency: Double) {
        publishedLock.lock()
        publishedEffectLatency = effectLatency
        publishedLock.unlock()
    }

    // MARK: - Graph

    private func buildGraph(
        effects: [AVAudioUnit],
        virtual: AudioDevice,
        monitor: AudioDevice,
        layout: AggregateChannelLayout,
        isMonitorEnabled: Bool
    ) throws {
        let deviceFormat = engine.outputNode.inputFormat(forBus: 0)
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // Barriered like the rest: reaching for the main mixer is not a plain property read,
        // it lazily attaches a node.
        let mixer = try withGraphBarrier("resolving main mixer") { engine.mainMixerNode }

        EngineLog.logger.info(
            """
            formats before start — input \(inputFormat.channelCount, privacy: .public)ch @ \
            \(inputFormat.sampleRate, privacy: .public)Hz, \
            outputNode.input \(deviceFormat.channelCount, privacy: .public)ch @ \
            \(deviceFormat.sampleRate, privacy: .public)Hz, \
            outputNode.output \
            \(self.engine.outputNode.outputFormat(forBus: 0).channelCount, privacy: .public)ch @ \
            \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate, privacy: .public)Hz
            """
        )

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioCoreError.message(
                """
                The input device reported no usable format. This is almost always a missing \
                microphone permission — grant PlugInput access under System Settings > \
                Privacy & Security > Microphone.
                """
            )
        }

        // Every mutation below goes through a barrier. `attach`, `connect`, `prepare` and
        // `installTap` all report misuse by *raising*, and an Objective-C exception unwinds past
        // this function's `throws` and aborts the process. The labels are what name the failing
        // step afterwards, since the exception text says what the runtime objected to but never
        // which call it came from.
        // Attach every unit before wiring any of them: `connect` requires both endpoints to be
        // attached, and doing it in one pass keeps `effectNodes` complete for teardown even if a
        // later connect raises.
        for effect in effects {
            try withGraphBarrier("attaching \(effect.auAudioUnit.componentName ?? "effect")") {
                engine.attach(effect)
                // Recorded as we go, so a raise part-way through still leaves `stopOnQueue`
                // every unit it needs to detach.
                effectNodes.append(effect)
            }
        }

        // The chain, in order: input → effects[0] → … → effects[n-1] → mixer. With no effects
        // this collapses to the single input → mixer connection, which is exactly what the
        // one-slot version did.
        var source: AVAudioNode = inputNode
        for (index, effect) in effects.enumerated() {
            try withGraphBarrier("connecting chain position \(index + 1)") {
                engine.connect(source, to: effect, format: inputFormat)
            }
            source = effect
        }
        try withGraphBarrier("connecting chain to mixer") {
            engine.connect(source, to: mixer, format: inputFormat)
        }

        try withGraphBarrier("connecting mixer to output") {
            engine.connect(mixer, to: engine.outputNode, format: deviceFormat)
        }
        try installInputTap(on: inputNode, format: inputFormat)

        try withGraphBarrier("preparing engine") { engine.prepare() }
        // Barriered as well as `try`-ed. `start()` throws properly for the failures it
        // anticipates — the `-10875` of gotcha #19 among them — and the barrier passes those
        // through unchanged; this only adds cover for the ones it raises instead.
        try withGraphBarrier("starting engine") { try engine.start() }

        // Published for the UI's latency badge — read here, on the queue that owns the nodes.
        // Summed across the chain, because latency accumulates: four plugins at 3 ms each is
        // 12 ms of delay on the user's own voice, which is the number that matters to them.
        publish(effectLatency: effects.reduce(0) { $0 + $1.auAudioUnit.latency })

        EngineLog.logger.info(
            """
            engine started: input \(inputFormat.channelCount, privacy: .public)ch @ \
            \(inputFormat.sampleRate, privacy: .public)Hz, device \
            \(deviceFormat.channelCount, privacy: .public)ch @ \
            \(deviceFormat.sampleRate, privacy: .public)Hz, \
            chain \(Self.describe(effects), privacy: .public)
            """
        )

        // After start, because preparing the engine reconfigures the output unit.
        try applyOutputChannelMap(
            virtualUID: virtual.uid,
            monitorUID: monitor.uid,
            layout: layout,
            isMonitorEnabled: isMonitorEnabled
        )
    }

    /// The chain as one log-friendly line: "LALA → Pro-L 2", or "none" when empty.
    ///
    /// Worth logging in full rather than as a count. The order is the thing that decides what
    /// the signal sounds like, and it is the thing the log cannot otherwise show.
    nonisolated static func describe(_ effects: [AVAudioUnit]) -> String {
        guard !effects.isEmpty else { return "none" }
        return effects
            .map { $0.auAudioUnit.componentName ?? "unnamed" }
            .joined(separator: " → ")
    }

    /// Installs the metering tap, having first guaranteed the bus is free.
    ///
    /// `installTap` on a bus that already carries one does not return an error — it raises
    /// `NSInternalInconsistencyException` ("required condition is false: nullptr == Tap()") from
    /// Objective-C, which unwinds straight past every Swift `do/catch` in this file and aborts
    /// the process. It killed the app on plugin switches: `selectPlugin` cycles the engine, and
    /// any cycle that began with the engine already self-stopped left the previous tap in place.
    /// The `removeInputTap()` here is belt-and-braces to `stopOnQueue`'s, and the barrier is a
    /// third line of defence behind both. Order matters: keep clearing the bus first. The
    /// barrier turns this crash into a message, which is strictly better than dying, but a
    /// start that fails is still a start that fails — it is not a licence to stop preventing it.
    private func installInputTap(on node: AVAudioNode, format: AVAudioFormat) throws {
        removeInputTap()
        try withGraphBarrier("installing input tap") {
            node.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format,
                block: Self.peakTap(writingTo: peakLevel)
            )
        }
        isTapInstalled = true
    }

    /// Idempotent. Touches `engine.inputNode` only when a tap is known to be installed —
    /// merely accessing that node makes `AVAudioEngine` configure a capture chain.
    private func removeInputTap() {
        guard isTapInstalled else { return }
        ignoringObjCException("removing input tap") {
            engine.inputNode.removeTap(onBus: 0)
        }
        // Cleared even if removal raised. What the tap's state is at that point is unknowable,
        // and leaving the flag set would make every later attempt re-run the same failing
        // removal; `installInputTap` clearing the bus first is the backstop either way.
        isTapInstalled = false
    }

    /// The tap block, built `nonisolated` on purpose. Do not inline this back into the method.
    ///
    /// AVFAudio calls the block from `RealtimeMessenger.mServiceQueue`. A closure written
    /// inline inside a method of this `@MainActor` class **inherits main-actor isolation** —
    /// dropping the `self` capture does not help, because the isolation belongs to the closure
    /// rather than to what it captures. Swift's executor check then kills the process with
    /// `EXC_BREAKPOINT` on the first audio buffer. Note the timing: with the microphone denied
    /// no buffers arrive at all, so this survives every launch test and only fires once real
    /// audio flows. Building the block outside any isolation, and marking it `@Sendable`, is
    /// what makes it callable from the audio thread. Covered by `InputTapTests`.
    nonisolated static func peakTap(writingTo peakLevel: PeakLevel) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }

            var peak: Float = 0
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channel[frame]))
            }
            peakLevel.record(peak)
        }
    }

    // MARK: - Verification and channel maps

    private func verifyBinding(to deviceID: AudioObjectID) throws {
        let boundInput = EngineDeviceBinding.currentDevice(of: engine.inputNode.audioUnit)
        let boundOutput = EngineDeviceBinding.currentDevice(of: engine.outputNode.audioUnit)
        guard boundInput == deviceID, boundOutput == deviceID else {
            throw AudioCoreError.message(
                "engine bound to input \(boundInput.map(String.init) ?? "?") / "
                    + "output \(boundOutput.map(String.init) ?? "?"), expected \(deviceID)"
            )
        }
    }

    private func applyInputChannelMap(inputUID: String, layout: AggregateChannelLayout) throws {
        guard let offset = layout.inputOffsets[inputUID] else {
            throw AudioCoreError.message("input device is not part of the aggregate")
        }
        guard let unit = engine.inputNode.audioUnit else {
            throw AudioCoreError.message("input node has no audio unit")
        }

        var map: [Int32] = [Int32(offset)]
        try checkStatus(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                1,
                &map,
                UInt32(MemoryLayout<Int32>.size * map.count)
            ),
            "input channel map"
        )

        // Read back, per gotcha #5 — a `noErr` write is not proof the map took. A map that
        // silently failed to apply is the difference between capturing the microphone and
        // capturing whatever was last written to the virtual device.
        var readBack = [Int32](repeating: -2, count: map.count)
        var readBackSize = UInt32(MemoryLayout<Int32>.size * map.count)
        let readStatus = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            1,
            &readBack,
            &readBackSize
        )
        guard readStatus == noErr, readBack == map else {
            throw AudioCoreError.message(
                "input channel map did not stick: wrote \(map), read back "
                    + (readStatus == noErr ? "\(readBack)" : "OSStatus \(readStatus)")
            )
        }

        // The node's own channel count is logged alongside, because the two disagreeing is a
        // silent-signal failure the map read-back alone cannot catch.
        let nodeChannels = engine.inputNode.outputFormat(forBus: 0).channelCount
        EngineLog.logger.info(
            """
            input channel map \(map.description, privacy: .public) for \
            \(inputUID, privacy: .public) — node reports \(nodeChannels, privacy: .public)ch
            """
        )
    }

    private func applyOutputChannelMap(
        virtualUID: String,
        monitorUID: String,
        layout: AggregateChannelLayout,
        isMonitorEnabled: Bool
    ) throws {
        let total = layout.totalOutputChannels
        guard total > 0, let unit = engine.outputNode.audioUnit else {
            throw AudioCoreError.message("aggregate reports no output channels")
        }

        // Fan the stereo bus into the virtual pair, and into the monitor pair only when
        // monitoring is on. Writing every destination pair makes this robust to subdevice
        // ordering; a `-1` entry is CoreAudio's "feed this channel nothing".
        //
        // Muting the monitor here rather than dropping it from the aggregate is deliberate: the
        // aggregate's channel layout then stays identical whichever way the toggle sits, so
        // flipping it cannot shift the virtual device's offsets. The user's reason for wanting
        // it is speakers — the processed signal coming out loud enough for the microphone to
        // pick it back up is a feedback loop, and this is the switch that opens it.
        let destinations = isMonitorEnabled ? [virtualUID, monitorUID] : [virtualUID]
        var map = [Int32](repeating: -1, count: total)
        for uid in destinations {
            guard let offset = layout.outputOffsets[uid] else { continue }
            if offset < total { map[offset] = 0 }
            if offset + 1 < total { map[offset + 1] = 1 }
        }

        try checkStatus(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                0,
                &map,
                UInt32(MemoryLayout<Int32>.size * total)
            ),
            "output channel map"
        )

        let virtualOffset = layout.outputOffsets[virtualUID] ?? -1
        let monitorOffset = layout.outputOffsets[monitorUID] ?? -1
        EngineLog.logger.info(
            """
            output channel map \(map.description, privacy: .public) — \
            virtual at \(virtualOffset, privacy: .public), \
            monitor at \(monitorOffset, privacy: .public) \
            (\(isMonitorEnabled ? "monitoring on" : "monitoring muted", privacy: .public))
            """
        )
    }

    /// Each distinct device once, in the order the channel maps assume.
    ///
    /// **The input device must come first.** Putting the virtual device first was tried, to make
    /// the aggregate usable directly as a "PlugInput" microphone by other apps, and it does not
    /// work — see gotcha #19. The short version: the aggregate really does expose 7 input
    /// channels, but `AVAudioEngine`'s input node only ever reports 2, so an input channel map
    /// indexing past channel 1 is accepted by `AudioUnitSetProperty` (and reads back correctly)
    /// and then fails `engine.start()` with `IsFormatSampleRateAndChannelCountValid`. Keeping
    /// the input first keeps its offset at 0, which is the only range that works.
    ///
    /// Every offset the channel maps use is derived from this order by
    /// `AggregateChannelLayout`, so the maps follow automatically; nothing here is hardcoded.
    /// Collapses naturally when monitor and input are the same device — common with an
    /// interface that has its own headphone jack.
    /// `nonisolated` because it derives a value from its arguments and touches no engine
    /// state — that also makes it directly testable without hopping to the main actor.
    nonisolated static func orderedSubDevices(
        input: AudioDevice,
        virtual: AudioDevice,
        monitor: AudioDevice
    ) -> [AudioDevice] {
        var ordered: [AudioDevice] = []
        for device in [input, virtual, monitor] where !ordered.contains(where: { $0.uid == device.uid }) {
            ordered.append(device)
        }
        return ordered
    }
}
