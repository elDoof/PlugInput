import AVFoundation
import CoreAudio
import Foundation

/// Drives mic → optional effect → (headphones + virtual device) over a private aggregate.
///
/// The start sequence here is not arbitrary. Every step is one that Phase 0 proved necessary
/// against real hardware, and several of them fail *silently* if reordered or skipped:
///
/// 1. Build a private aggregate of `[input, virtual]` plus the monitor *only if monitoring is
///    on*, input as clock master. Leaving the monitor out is what stops PlugInput opening the
///    user's output interface — and re-sizing its buffer — for a leg carrying nothing.
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
    //
    // A `var`, and replaced on every start — for engine hygiene, **not** as a fix for the
    // sample-rate bug described below. It was tried as that fix and did not work.
    //
    // What it does buy: the previous start's AUHALs are disposed rather than left initialised
    // and pointing at an aggregate that has already been destroyed, and no graph state carries
    // across a start.
    //
    // A node's graph-side format is fixed when the node materialises, against whatever device
    // was current at that moment — and replacing the engine does not change that, because the
    // device is still bound after the fact. This was a silent-microphone bug for a release
    // cycle; the fix lives in `buildGraph`, which connects at the hardware faces. Do not
    // "simplify" those connections back to `outputNode.inputFormat` / `inputNode.outputFormat`.
    private var engine = AVAudioEngine()
    private var aggregate: AggregateDevice?
    /// The chain's units, in signal order. Held so teardown can detach every one of them —
    /// a unit left attached to a stopped engine is a leak the next start inherits.
    private var effectNodes: [AVAudioUnit] = []

    /// The capture path, which is no longer the input node's own connection. See gotcha #36.
    ///
    /// `AVAudioEngine`'s input node captures audio it will not deliver downstream on this
    /// platform: a tap on it reports real levels while everything connected below it receives
    /// exact digital silence. The tap is therefore the capture, this ring carries the frames,
    /// and `inputSourceNode` renders them into the chain. `inputSinkNode` is connected to the
    /// input node and holds `outputVolume` at zero — it exists only so that *something* is
    /// connected to the input node, which is what pulls its graph-side format onto the
    /// hardware rate (gotcha #27). Silent rather than absent, so that an OS which starts
    /// delivering input again cannot leak an unprocessed dry path around the chain.
    private var inputRing: InputRingBuffer?
    /// The same ring as `inputRing`, guarded by `publishedLock` so the meter can read it.
    private var publishedRing: InputRingBuffer?
    private var inputSourceNode: AVAudioSourceNode?
    private var inputSinkNode: AVAudioMixerNode?

    /// Seconds of audio a tap buffer must hold. **Do not lower this below 0.1.**
    ///
    /// The input tap has a floor of roughly 100ms between callbacks that a smaller request does
    /// not move: asking for 512 frames at 48kHz produced 4096-frame buffers *still arriving
    /// every 100ms*, and 4096 frames is only 85ms of audio, so the ~704 frames the hardware
    /// produced beyond each buffer were dropped before the tap ever saw them — a silent, and
    /// exactly constant, 15% of the signal. Measured: 41,015 frames/sec supplied against 48,058
    /// requested, which is 4096/4800 to three decimal places. The audible result is a crunch,
    /// not a dropout, because the shortfall is zero-filled rather than delayed.
    ///
    /// So the buffer has to hold *more* than the callback interval, and since the interval is
    /// fixed in time the size has to come from the sample rate. 0.125s leaves 25% of margin
    /// over the floor; it measured 47,858 frames/sec with starvation flat at zero, as did
    /// 0.171s. The cost is latency — this is the dominant term in the capture path — so it is
    /// as close to the floor as the measurement supports rather than a round larger number.
    private static let inputTapSeconds = 0.125

    /// Frames requested per tap callback, at `sampleRate`. A hint AVFAudio may round up — what
    /// it will not do is call more often than every 100ms. See `inputTapSeconds`.
    private static func inputTapFrames(at sampleRate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount((sampleRate * inputTapSeconds).rounded(.up))
    }

    /// Ring capacity, in frames: several tap buffers deep, so the ring can hold what has
    /// arrived while the render drains it.
    ///
    /// It was originally one tap buffer exactly, which is the worst possible size — the render
    /// emptied it before each next callback landed, so `available` oscillated between full and
    /// zero and every scheduling jitter became a zero-filled gap.
    private static let inputRingCapacityFrames = 32768

    /// Whether a tap is currently installed on the input node's bus 0.
    ///
    /// Tracked separately because a tap's lifetime is **not** the engine's: `AVAudioEngine`
    /// stops itself on some device reconfigurations, and the tap survives that. Keying removal
    /// off `engine.isRunning` therefore leaked the tap, and the next `installTap` raised
    /// `nullptr == Tap()` — an Objective-C exception no Swift `try` can catch, so the process
    /// aborted outright. See the crash note on `installInputTap`.
    private var isTapInstalled = false

    /// Whether a meter tap is installed on the main mixer's bus 0. Tracked separately from the
    /// input tap for the same reason that one is tracked at all (gotcha #14): a tap outlives
    /// the engine that was running when it was installed.
    private var isOutputTapInstalled = false

    /// Written by the realtime tap, read by the UI; carries its own lock.
    private let peakLevel = PeakLevel()

    /// Peak of what leaves the chain, measured at the main mixer.
    ///
    /// The input meter alone cannot tell the two halves of this app apart. Capture and the
    /// route out to the virtual device fail the same way — exact digital silence with every
    /// layer reporting success — so a single meter leaves "no audio in Discord" ambiguous
    /// between a microphone that is not arriving and a chain output that is not being carried.
    /// Read together, they name the half: input moving with output at zero is the graph losing
    /// it; both at zero is capture.
    private let outputPeakLevel = PeakLevel()

    /// Values the UI reads, published out from `queue` under a lock.
    ///
    /// The UI must never reach into `queue` to read them: a `queue.sync` from the main thread
    /// while a start is in flight would block on exactly the call this class exists to keep off
    /// the main thread.
    private let publishedLock = NSLock()
    private var publishedState: State = .stopped
    private var publishedEffectLatency: Double = 0

    /// Told when the engine tears itself down for a reason the user did not ask for. Guarded by
    /// `publishedLock` like the rest of the cross-thread state.
    private var unexpectedStopHandler: (@Sendable (String) -> Void)?
    private var configurationObserver: (any NSObjectProtocol)?

    public init() {
        // `AVAudioEngine` stops *itself* when the device it is bound to is reconfigured — an
        // interface unplugged, a sample rate changed underneath it, an aggregate losing a
        // subdevice. Nothing was listening for that, so the app went on believing it was
        // running: menu bar icon lit, meter ticking against a dead tap, and — the part that
        // actually harmed other software — **the aggregate still alive**, holding the user's
        // input and output devices open indefinitely while producing nothing.
        //
        // Registered here rather than at start, because the notification can arrive during the
        // teardown that follows one. `handleConfigurationChange` hops to `queue` and re-checks
        // the state there, which is what makes that safe.
        observeConfigurationChanges()
    }

    /// Watches the *current* engine. Re-registered whenever the engine is replaced, because the
    /// notification is scoped to the instance that posts it.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Swaps in a clean engine. Call only after `stopOnQueue`, which detaches the effect nodes —
    /// a node still attached to the discarded engine cannot be attached to the new one.
    private func replaceEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine = AVAudioEngine()
        isTapInstalled = false
        observeConfigurationChanges()
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Registers the callback for an unexpected stop. Set once, before the first start.
    ///
    /// The handler is invoked from the engine queue, never the main actor — callers hop.
    public func onUnexpectedStop(_ handler: @escaping @Sendable (String) -> Void) {
        publishedLock.lock()
        unexpectedStopHandler = handler
        publishedLock.unlock()
    }

    private func handleConfigurationChange() {
        queue.async {
            // Only act if we believed we were running. A configuration change raised by our own
            // teardown, or while already stopped, means nothing and must not be reported.
            guard self.state == .running else { return }

            // A configuration change is not, by itself, a problem — and treating it as one was a
            // bug. `AVAudioEngine` posts this notification for its *own* reconfigurations too,
            // and applying the output channel map after `start()` is enough to raise one: the
            // engine came up correctly and then tore itself down 47ms later, every single time.
            //
            // The condition that actually matters is whether the engine is still running. It
            // stops *itself* when the device underneath it disappears, and that is the case
            // worth reacting to, because it is the one that would otherwise leave the aggregate
            // holding the user's hardware open indefinitely.
            guard !self.engine.isRunning else {
                EngineLog.logger.info(
                    "audio configuration changed, engine still running — no action needed"
                )
                return
            }

            EngineLog.logger.error(
                "audio device configuration changed while running — tearing the engine down"
            )
            self.stopOnQueue()

            self.publishedLock.lock()
            let handler = self.unexpectedStopHandler
            self.publishedLock.unlock()
            handler?(
                "The audio devices changed and PlugInput stopped. Press Start to resume."
            )
        }
    }

    /// A plugin being handed from the UI to the engine queue.
    ///
    /// `AVAudioUnit` is not `Sendable`, and this crossing is real rather than theoretical: the
    /// unit is created on the main actor, driven by `AVAudioEngine` on its own threads, and
    /// shown in a window by AppKit. The box makes the boundary visible in the signature instead
    /// of hiding it behind an implicit capture — the compiler cannot prove this safe, so the
    /// claim belongs in the open.
    ///
    /// **What actually makes it hold, stated honestly.** The array itself is handed over once
    /// and never mutated afterwards. The *units* are a different matter: `AppModel.setBypass`
    /// writes `shouldBypassEffect` on a unit the engine is rendering, and a plugin's own window
    /// mutates its parameters continuously while audio flows. Both are deliberate — live bypass
    /// with no dropout is the point of it — and both are safe because `AUAudioUnit` is
    /// documented to accept parameter and bypass changes from any thread, not because this type
    /// prevents them. An earlier version of this comment claimed the UI "never mutates one the
    /// engine is using", which was simply untrue and is the sort of thing a maintainer would
    /// have built on.
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
        /// `nil` means monitoring is off, and is the *only* way to express that. See
        /// `orderedSubDevices`: an off monitor is absent from the aggregate, not muted in it,
        /// so a separate `isMonitorEnabled` flag beside a non-optional device would be a second
        /// source of truth for one fact — and the pair could disagree.
        let monitor: AudioDevice?
        let virtual: AudioDevice
        let effects: Effects
        /// Which of the input device's own channels carries the microphone, zero-based.
        let inputChannel: Int
    }

    // MARK: - Lifecycle

    /// Awaiting this keeps the caller's thread — in practice the main thread — free while
    /// CoreAudio negotiates. See the isolation note above; this signature is the fix for it.
    /// Pass `monitor: nil` to run without a monitoring leg — the output device is then not
    /// opened at all, which is what keeps PlugInput out of the way of other audio software.
    ///
    /// `inputChannel` is zero-based and relative to the input *device*, not to the aggregate;
    /// it selects which of a multi-input interface's channels carries the microphone.
    public func start(
        input: AudioDevice,
        monitor: AudioDevice?,
        virtual: AudioDevice,
        effects: Effects,
        inputChannel: Int = 0
    ) async throws {
        let request = StartRequest(
            input: input,
            monitor: monitor,
            virtual: virtual,
            effects: effects,
            inputChannel: inputChannel
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

    /// Teardown for `willTerminate`, bounded so that quitting can never hang the app.
    ///
    /// Synchronous because there is nothing to await at that point, but **not** a `queue.sync`.
    /// It used to be, on the reasoning that teardown negotiates no permissions — which is true
    /// of the *body* and irrelevant to the *queue*. The queue is held for the entire duration of
    /// a start, and a start blocks inside `AudioDeviceCreateIOProcID` until the user answers the
    /// microphone dialog. So: first run, click Start, then Quit before answering the dialog, and
    /// the main thread blocked forever on a queue that was waiting on a dialog the frozen app
    /// could no longer show. Force quit was the only way out, and it took the aggregate with it.
    ///
    /// The bound turns that into a two-second worst case. If the queue does not answer,
    /// `AggregateRegistry` destroys the devices directly — it holds raw IDs behind a lock
    /// precisely so cleanup is reachable without the queue and without the main actor, which is
    /// the one step that genuinely cannot be skipped (gotcha #7, and gotcha #20 for what a
    /// survivor costs the *next* launch).
    public func stopForTermination(timeout: TimeInterval = 2) {
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            self.stopOnQueue()
            finished.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .timedOut else { return }
        EngineLog.logger.error(
            """
            engine queue did not answer within \(timeout, privacy: .public)s — \
            destroying aggregates directly
            """
        )
        AggregateRegistry.destroyAll()
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
        replaceEngine()

        let subDevices = Self.orderedSubDevices(input: input, virtual: virtual, monitor: monitor)

        do {
            // Private. Publishing this aggregate so other apps could select it directly was
            // tried and does not work — gotchas #17 and #19. The name now comes from the HAL
            // driver instead, which is what other apps select.
            //
            // Inside the `do` so that a creation failure still publishes `.failed`. It used to
            // sit above, where a throw escaped without ever setting the state the UI reads.
            let device = try AggregateDevice(
                uid: VirtualMicrophone.aggregateUID,
                name: "PlugInput Engine",
                subDevices: subDevices,
                clockSourceUID: input.uid
            )
            aggregate = device

            try EngineDeviceBinding.bind(deviceID: device.id, on: engine)
            try verifyBinding(to: device.id)
            logBufferSize(of: device.id)
            try applyInputChannelMap(
                input: input,
                channel: request.inputChannel,
                layout: device.layout
            )

            try buildGraph(
                effects: request.effects.units,
                virtual: virtual,
                monitor: monitor,
                layout: device.layout,
                aggregateID: device.id
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
        removeOutputTap()
        if engine.isRunning {
            ignoringObjCException("stopping engine") { engine.stop() }
        }
        for node in effectNodes {
            ignoringObjCException("detaching effect") { engine.detach(node) }
        }
        releaseEffectsOnMain()
        // The source and sink carry no vendor code, so unlike the effect units (gotcha #29)
        // they can be released on whatever thread gets here.
        if let inputSourceNode {
            ignoringObjCException("detaching input source") { engine.detach(inputSourceNode) }
        }
        if let inputSinkNode {
            ignoringObjCException("detaching input sink") { engine.detach(inputSinkNode) }
        }
        inputSourceNode = nil
        inputSinkNode = nil
        inputRing = nil
        publishedLock.lock()
        publishedRing = nil
        publishedLock.unlock()
        aggregate?.destroy()
        aggregate = nil
        peakLevel.reset()
        outputPeakLevel.reset()
        publish(state: .stopped)
        publish(effectLatency: 0)
    }

    /// Hands the chain's units to the main queue and lets go of them there, never here.
    ///
    /// **The engine queue must never perform the *last* release of an `AVAudioUnit`.** Dropping
    /// the final reference runs `-[AVAudioNode dealloc]` → `AudioComponentInstanceDispose` →
    /// the vendor's own teardown, on whatever thread let go. Plugins tear down their interface
    /// in there: iZotope's Nectar 4 calls `-[NSWindow close]`, which is AppKit, which traps with
    /// "Must only be used from the main thread" and aborts the process. Confirmed from a crash
    /// report — the faulting thread was `com.pluginput.engine`, inside `stopOnQueue`, releasing
    /// this exact array.
    ///
    /// It fires on **removing a slot**, which is the common half of switching plugins:
    /// `AppModel.removeSlot` drops its own reference first, so by the time the restart tears the
    /// graph down, `effectNodes` is holding the only one left. Add and reorder keep the unit in
    /// `loadedUnits` throughout, which is why they were survivable and remove was not.
    ///
    /// The same hop is why teardown-shaped plugin bugs stop being ours: a JUCE plugin disposed
    /// off the message thread is a documented crash on the vendor's side too, and the main
    /// queue *is* their message thread.
    ///
    /// `releaseOnMainThread` carries the how, including what it means at termination.
    private func releaseEffectsOnMain() {
        releaseOnMainThread(&effectNodes)
    }

    // MARK: - Readable from any thread

    /// Peak of the most recent input buffer, 0...1.
    public var inputPeak: Float {
        peakLevel.current
    }

    /// Peak of the signal leaving the chain at the main mixer, 0...1. See `outputPeakLevel`.
    public var outputPeak: Float {
        outputPeakLevel.current
    }

    public var state: State {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedState
    }

    /// Capture-path health: frames buffered, plus frames lost in each direction. `nil` when
    /// no engine is running.
    ///
    /// Worth exposing because gotcha #36 moved capture off the input node's own downstream
    /// connection and onto a tap and a ring, and a ring between two audio threads fails in two
    /// directions that sound identical from outside. `dropped` rising means the tap is
    /// outrunning the render; `starved` rising means the reverse. Both zero with `available`
    /// steady is the healthy shape.
    public var inputRingStatus: (available: Int, counts: InputRingBuffer.Counts)? {
        publishedLock.lock()
        let ring = publishedRing
        publishedLock.unlock()
        guard let ring else { return nil }
        return (ring.availableFrames, ring.counts)
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
        monitor: AudioDevice?,
        layout: AggregateChannelLayout,
        aggregateID: AudioObjectID
    ) throws {
        let inputNode = engine.inputNode
        // Barriered like the rest: reaching for the main mixer is not a plain property read,
        // it lazily attaches a node.
        let mixer = try withGraphBarrier("resolving main mixer") { engine.mainMixerNode }

        // Connect at each node's **hardware** face — `outputNode.outputFormat` and
        // `inputNode.inputFormat` — never at its graph face. This is gotcha #4, and reading the
        // graph face instead is what made it silently wrong for a release cycle.
        //
        // A node materialises against whatever device was current at that moment, which is the
        // system default, and pointing `kAudioOutputUnitProperty_CurrentDevice` at the aggregate
        // afterwards updates only the hardware face. The graph face keeps the *old* device's
        // rate — so with a 44.1kHz default output and a 48kHz microphone the graph ran at
        // 44.1kHz, the input arrived as exact digital silence, and `engine.start()` returned
        // success anyway. Connecting at the hardware format is the only thing that pulls the
        // graph face across: spinning the runloop for the configuration-change notification,
        // `engine.reset()`, and writing `CurrentDevice` a second time were each measured to do
        // nothing at all.
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)

        // The output side is wired first, so the mixer has already adopted the hardware rate
        // before anything is connected into it.
        try withGraphBarrier("connecting mixer to output") {
            engine.connect(mixer, to: engine.outputNode, format: outputFormat)
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)

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

        // Connect the input node to a silent sink before reading its graph face.
        //
        // Nothing downstream consumes this: it is the act of connecting that drags the input
        // node's graph-side format onto the hardware rate, and reading `outputFormat` before
        // any connection returns the *system default* device's rate instead — which is gotcha
        // #27, a silent microphone for a whole release cycle. The volume is zero so that this
        // path contributes nothing even if a future macOS starts delivering input downstream
        // again; the chain below is the only route to the mixer.
        let sink = AVAudioMixerNode()
        sink.outputVolume = 0
        try withGraphBarrier("attaching input sink") { engine.attach(sink) }
        inputSinkNode = sink
        try withGraphBarrier("connecting input to sink") {
            engine.connect(inputNode, to: sink, format: inputFormat)
        }
        try withGraphBarrier("connecting sink to mixer") {
            engine.connect(sink, to: mixer, format: inputFormat)
        }

        // Read back rather than reused: the tap's format has to match what the node actually
        // produces, and `installTap` signals a mismatch by raising. Connecting above is what
        // moved the graph face onto the hardware rate, so this is the proof it moved.
        let tapFormat = inputNode.outputFormat(forBus: 0)

        // The real capture path. The tap writes into `ring`; this node renders out of it.
        //
        // **Mono, deliberately, and it has to be.** The input channel map has already chosen
        // one of the device's channels (gotcha #26) and delivers it as channel 0, so a wider
        // chain would carry the interface's other inputs as passengers — on a 14-input Apollo,
        // thirteen of them. It is also the difference between working and silent: an
        // `AVAudioMixerNode` fed 14 channels with no channel layout to downmix by emits
        // silence, which is exactly what the first version of this fix measured, while mono
        // into the stereo mixer measured -14.0 dBFS on the same graph.
        let chainFormat = AVAudioFormat(standardFormatWithSampleRate: tapFormat.sampleRate, channels: 1)
        guard let chainFormat else {
            throw AudioCoreError.message(
                "could not build a mono chain format at \(tapFormat.sampleRate)Hz"
            )
        }
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: Self.inputRingCapacityFrames)
        inputRing = ring
        publishedLock.lock()
        publishedRing = ring
        publishedLock.unlock()
        // `PLUGINPUT_TEST_TONE=1` feeds the chain a 440Hz tone instead of the microphone.
        //
        // This app has two independently silent halves — capture into the ring, and the route
        // from the chain out through the aggregate's output channel map to the virtual device —
        // and both fail by producing exact digital silence rather than an error. Swapping the
        // chain's head for a signal of known amplitude is what tells the two apart without
        // rebuilding: a tone that reaches `Spike`'s listener proves the whole output leg,
        // leaving capture as the only place the microphone can be going missing.
        let isTestTone = ProcessInfo.processInfo.environment["PLUGINPUT_TEST_TONE"] == "1"
        if isTestTone {
            EngineLog.logger.info("PLUGINPUT_TEST_TONE set — feeding the chain a 440Hz tone")
        }
        let sourceNode = AVAudioSourceNode(
            format: chainFormat,
            renderBlock: isTestTone
                ? Self.toneRender(sampleRate: chainFormat.sampleRate)
                : Self.inputRender(reading: ring)
        )
        try withGraphBarrier("attaching input source") { engine.attach(sourceNode) }
        inputSourceNode = sourceNode

        // The chain, in order: source → effects[0] → … → effects[n-1] → mixer. With no effects
        // this collapses to the single source → mixer connection, which is exactly what the
        // one-slot version did.
        var source: AVAudioNode = sourceNode
        for (index, effect) in effects.enumerated() {
            try withGraphBarrier("connecting chain position \(index + 1)") {
                engine.connect(source, to: effect, format: chainFormat)
            }
            source = effect
        }
        try withGraphBarrier("connecting chain to mixer") {
            engine.connect(source, to: mixer, format: chainFormat)
        }

        try installInputTap(on: inputNode, format: tapFormat, into: ring)
        try installOutputTap(on: mixer)

        // Every face of every node, plus what the hardware actually says, logged once the graph
        // is fully wired. A graph running at a different rate than the device is silent, not
        // loud, and start() reports success either way — so these six numbers agreeing is the
        // one check that distinguishes a working start from a silent one at a glance.
        let hardwareRate = (try? SampleRate.current(aggregateID)) ?? 0
        let outputGraphRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        EngineLog.logger.info(
            """
            formats before start — \
            inputNode.input \(inputFormat.channelCount, privacy: .public)ch @ \
            \(inputFormat.sampleRate, privacy: .public)Hz, \
            inputNode.output \(tapFormat.channelCount, privacy: .public)ch @ \
            \(tapFormat.sampleRate, privacy: .public)Hz, \
            outputNode.input \(outputGraphRate, privacy: .public)Hz, \
            outputNode.output \(outputFormat.channelCount, privacy: .public)ch @ \
            \(outputFormat.sampleRate, privacy: .public)Hz, \
            aggregate nominal \(hardwareRate, privacy: .public)Hz
            """
        )

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
            \(outputFormat.channelCount, privacy: .public)ch @ \
            \(outputFormat.sampleRate, privacy: .public)Hz, \
            chain \(Self.describe(effects), privacy: .public)
            """
        )

        // After start, because preparing the engine reconfigures the output unit.
        try applyOutputChannelMap(
            virtualUID: virtual.uid,
            monitorUID: monitor?.uid,
            layout: layout
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
    private func installInputTap(
        on node: AVAudioNode,
        format: AVAudioFormat,
        into ring: InputRingBuffer
    ) throws {
        removeInputTap()
        try withGraphBarrier("installing input tap") {
            node.installTap(
                onBus: 0,
                bufferSize: Self.inputTapFrames(at: format.sampleRate),
                format: format,
                block: Self.captureTap(writingTo: peakLevel, into: ring)
            )
        }
        isTapInstalled = true
    }

    /// Meters the main mixer. Installed last, so the mixer has already settled on its final
    /// output format; the tap's format has to match what the node produces or `installTap`
    /// raises.
    private func installOutputTap(on node: AVAudioNode) throws {
        removeOutputTap()
        let format = node.outputFormat(forBus: 0)
        try withGraphBarrier("installing output tap") {
            node.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format,
                block: Self.peakTap(writingTo: outputPeakLevel)
            )
        }
        isOutputTapInstalled = true
    }

    /// Idempotent, and cleared even if removal raised — on the same terms as `removeInputTap`.
    private func removeOutputTap() {
        guard isOutputTapInstalled else { return }
        ignoringObjCException("removing output tap") {
            engine.mainMixerNode.removeTap(onBus: 0)
        }
        isOutputTapInstalled = false
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
    /// inline inside a method of a main-actor-isolated type **inherits that isolation** —
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

    /// The tap block that *is* the capture path: meter plus ring, on the audio thread.
    ///
    /// Built `nonisolated static` for the same reason as `peakTap` — a closure written inline
    /// in a method inherits that method's actor isolation, and AVFAudio calls this from
    /// `RealtimeMessenger.mServiceQueue`, where Swift's executor check kills the process on the
    /// first audio buffer. Nothing here allocates or locks beyond the ring's own unfair lock.
    nonisolated static func captureTap(
        writingTo peakLevel: PeakLevel,
        into ring: InputRingBuffer
    ) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)

            var peak: Float = 0
            for frame in 0..<frames {
                peak = max(peak, abs(channels[0][frame]))
            }
            peakLevel.record(peak)

            ring.write(from: channels, frames: frames)
        }
    }

    /// Reads the output unit's channel map back. `nil` when the unit will not report one.
    nonisolated static func readOutputChannelMap(_ unit: AudioUnit, count: Int) -> [Int32]? {
        var size = UInt32(MemoryLayout<Int32>.size * count)
        var readBack = [Int32](repeating: -2, count: count)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            0,
            &readBack,
            &size
        )
        guard status == noErr else { return nil }
        return readBack
    }

    /// A 440Hz tone at 0.2 amplitude, for `PLUGINPUT_TEST_TONE`. Matches `Spike`'s probe, so
    /// the harness's own 440Hz detector reports on it and not just the broadband number.
    ///
    /// Expect **-17.0 dBFS**, not -14.0: 0.2 amplitude is -13.98 dBFS and `mainMixerNode`
    /// equal-power pans this mono source to stereo, costing 3.01 dB. That discrepancy is
    /// written down in the Phase 0 notes because chasing it once cost a session.
    nonisolated static func toneRender(sampleRate: Double) -> AVAudioSourceNodeRenderBlock {
        final class Phase: @unchecked Sendable { var value: Double = 0 }
        let phase = Phase()
        let increment = 2.0 * Double.pi * 440.0 / sampleRate
        return { @Sendable _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(phase.value) * 0.2)
                phase.value += increment
                if phase.value > 2 * .pi { phase.value -= 2 * .pi }
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
    }

    /// The render block feeding the chain, pulling whatever the tap has captured.
    ///
    /// `withUnsafeTemporaryAllocation` keeps the channel-pointer scratch on the stack: this
    /// runs on the render thread, where a heap allocation is a dropout waiting for a busy
    /// moment. A read that comes up short zero-fills and reports silence rather than repeating
    /// stale audio.
    nonisolated static func inputRender(reading ring: InputRingBuffer) -> AVAudioSourceNodeRenderBlock {
        { @Sendable isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            let channels = min(buffers.count, ring.channelCount)
            guard channels > 0 else {
                isSilence.pointee = true
                return noErr
            }

            var filled = 0
            withUnsafeTemporaryAllocation(
                of: UnsafeMutablePointer<Float>.self,
                capacity: channels
            ) { scratch in
                for channel in 0..<channels {
                    guard let data = buffers[channel].mData else { return }
                    scratch[channel] = data.assumingMemoryBound(to: Float.self)
                }
                guard let base = scratch.baseAddress else { return }
                filled = ring.read(into: base, frames: frames)
            }

            if filled == 0 { isSilence.pointee = true }
            return noErr
        }
    }

    // MARK: - Verification and channel maps

    /// Records the buffer size the aggregate actually settled on. Deliberately read-only.
    ///
    /// This used to *write* a preferred 128 frames here. That is a latency preference, not a
    /// requirement — gotcha #9 measured the floor at 15 frames and recorded latency as a
    /// non-issue for this app — and the write was actively harmful: a CoreAudio aggregate
    /// pushes its buffer size down onto its subdevices, so PlugInput was reaching through the
    /// aggregate and re-sizing the user's own audio interface, which a DAW on that same
    /// interface hears as crackle and dropouts. Nothing restored the previous value on
    /// teardown, so the damage outlived the session.
    ///
    /// It was also a `try?` with no read-back, against the explicit advice on `BufferSize.set`
    /// and gotcha #5. Whatever the aggregate inherits is now simply reported.
    private func logBufferSize(of deviceID: AudioObjectID) {
        do {
            let frames = try BufferSize.current(deviceID)
            let range = try BufferSize.range(deviceID)
            EngineLog.logger.info(
                """
                aggregate buffer \(frames, privacy: .public) frames \
                (device supports \(range.lowerBound, privacy: .public)…\
                \(range.upperBound, privacy: .public)) — inherited, not set
                """
            )
        } catch {
            // Diagnostic only, so a failure here must not fail the start — but it is logged
            // rather than swallowed, which is what the old `try?` got wrong.
            EngineLog.logger.error(
                "could not read aggregate buffer size: \(String(describing: error), privacy: .public)"
            )
        }
    }

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

    /// Selects exactly one of the input device's channels and delivers it as mono.
    ///
    /// `channel` is zero-based within the *device*; `offset` is where that device's channels
    /// begin inside the aggregate, so the hardware index is the sum. This used to be hardcoded
    /// to the offset alone — always the device's first channel — which is correct for a
    /// built-in mic and silently wrong for an interface whose microphone is on input 2. The
    /// failure was the worst kind available here: `start()` succeeded, the meter read 0.0, and
    /// the UI blamed microphone permissions.
    ///
    /// **Caution, per gotcha #19.** A map value that indexes past what `AVAudioEngine`'s input
    /// node believes the device has is *accepted* by `AudioUnitSetProperty` and *reads back
    /// correctly*, and then fails `engine.start()` with
    /// `-10875 IsFormatSampleRateAndChannelCountValid`. The read-back below therefore proves
    /// less than it appears to; the bound checked here is the device's own channel count, and
    /// the real proof is a start that survives on multi-input hardware.
    private func applyInputChannelMap(
        input: AudioDevice,
        channel: Int,
        layout: AggregateChannelLayout
    ) throws {
        guard let offset = layout.inputOffsets[input.uid] else {
            throw AudioCoreError.message("input device is not part of the aggregate")
        }
        guard let unit = engine.inputNode.audioUnit else {
            throw AudioCoreError.message("input node has no audio unit")
        }
        guard channel >= 0, channel < input.inputChannels else {
            throw AudioCoreError.message(
                "\(input.name) has \(input.inputChannels) input channel(s); "
                    + "channel \(channel + 1) does not exist"
            )
        }

        var map: [Int32] = [Int32(offset + channel)]
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
            \(input.name, privacy: .public) — capturing channel \
            \(channel + 1, privacy: .public) of \(input.inputChannels, privacy: .public), \
            node reports \(nodeChannels, privacy: .public)ch
            """
        )
    }

    private func applyOutputChannelMap(
        virtualUID: String,
        monitorUID: String?,
        layout: AggregateChannelLayout
    ) throws {
        let total = layout.totalOutputChannels
        guard total > 0, let unit = engine.outputNode.audioUnit else {
            throw AudioCoreError.message("aggregate reports no output channels")
        }

        // Fan the stereo bus into the virtual pair, and into the monitor pair when there is
        // one. Writing every destination pair makes this robust to subdevice ordering; a `-1`
        // entry is CoreAudio's "feed this channel nothing".
        //
        // A nil `monitorUID` means the monitor device is not in the aggregate at all, so there
        // are no channels here to mute — see `orderedSubDevices` for why it is excluded rather
        // than muted. The user's reason for turning monitoring off is speakers: the processed
        // signal coming out loud enough for the microphone to pick it back up is a feedback
        // loop, and this is the switch that closes it.
        let destinations = [virtualUID, monitorUID].compactMap { $0 }
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

        // Read the map back, and set it again if it did not stick.
        //
        // Gotcha #5: a `noErr` write is not proof. `AVAudioEngine` reconfigures the output
        // unit's stream formats around `prepare` and `start`, and that reconfiguration
        // discards a channel map — so the write above can succeed and leave the unit on the
        // identity map, every frame going to the aggregate's first output pair and nothing to
        // a virtual device sitting further along. The failure is silent in both directions:
        // the engine reports running, and the monitor still works precisely because it *is*
        // the first pair, so only a separate process reading the virtual device sees the zeros.
        var settled = Self.readOutputChannelMap(unit, count: total)
        if settled != map {
            try checkStatus(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    0,
                    &map,
                    UInt32(MemoryLayout<Int32>.size * total)
                ),
                "output channel map (retry)"
            )
            settled = Self.readOutputChannelMap(unit, count: total)
        }
        EngineLog.logger.info(
            "output channel map readback \(settled?.description ?? "unreadable", privacy: .public)"
        )

        let virtualOffset = layout.outputOffsets[virtualUID] ?? -1
        let monitorOffset = monitorUID.flatMap { layout.outputOffsets[$0] } ?? -1
        EngineLog.logger.info(
            """
            output channel map \(map.description, privacy: .public) — \
            virtual at \(virtualOffset, privacy: .public), \
            monitor at \(monitorOffset, privacy: .public) \
            (\(monitorUID == nil ? "monitoring off, device not opened" : "monitoring on", privacy: .public))
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
    ///
    /// **A nil monitor is left out of the aggregate entirely, rather than muted.** An aggregate
    /// opens every subdevice it names, so keeping the monitor in the list and muting its
    /// channels meant PlugInput held the user's output interface the whole time it ran — and a
    /// CoreAudio aggregate pushes its IO buffer size down onto its subdevices, so a DAW sharing
    /// that interface got a second IOProc and a competing buffer request for a leg that was
    /// carrying silence. That was a real, reproduced source of interference with Ableton.
    ///
    /// The earlier rationale for muting instead — that a constant subdevice list keeps the
    /// virtual device's offsets stable across a monitor toggle — bought nothing:
    /// `AppModel.setMonitorEnabled` cycles the engine, so the aggregate is destroyed and
    /// rebuilt and every offset recomputed either way.
    ///
    /// `nonisolated` because it derives a value from its arguments and touches no engine
    /// state — that also makes it directly testable without hopping to the main actor.
    nonisolated static func orderedSubDevices(
        input: AudioDevice,
        virtual: AudioDevice,
        monitor: AudioDevice?
    ) -> [AudioDevice] {
        var ordered: [AudioDevice] = []
        for device in [input, virtual, monitor].compactMap({ $0 })
        where !ordered.contains(where: { $0.uid == device.uid }) {
            ordered.append(device)
        }
        return ordered
    }
}
