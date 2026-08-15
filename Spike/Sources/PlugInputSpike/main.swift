import AVFoundation
import CoreAudio
import Foundation

// Phase 0 spike: prove that a private aggregate can carry mic -> monitor + BlackHole,
// and that another app can read BlackHole at the same time.
//
// Usage: swift run PlugInputSpike [mic|tone|listen] [seconds]
// Ctrl-C at any point; the aggregate is destroyed on every exit path.
//
// The decisive test is two processes at once:
//   ./PlugInputSpike tone 20 &   # routes a 440Hz tone through the aggregate
//   ./PlugInputSpike listen 15   # opens BlackHole as a mic, like Zoom would

enum SpikeMode: String {
    /// Live microphone through the aggregate — the real use case.
    case mic
    /// A known tone through the aggregate, so the listener's result is unambiguous.
    case tone
    /// Read the virtual device as a separate process; prints PASS/FAIL.
    case listen
    /// Control: tone straight into the virtual device, no aggregate involved.
    case direct
}

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first.flatMap(SpikeMode.init(rawValue:)) ?? .mic
let runSeconds = Double(arguments.dropFirst().first ?? "") ?? 120
let virtualDeviceFragment = "BlackHole"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\nerror: \(message)\n".utf8))
    exit(1)
}

func heading(_ text: String) {
    print("\n\(text)")
    print(String(repeating: "-", count: 60))
}

func dbfsOf(_ amplitude: Float) -> Float {
    amplitude > 0 ? 20 * log10(amplitude) : -120
}

/// Roughly -40 dBFS. The tone is emitted at 0.2 amplitude (about -14 dBFS), so a real
/// detection clears this by a wide margin, while the device's own noise floor does not
/// concentrate at 440Hz and stays far below it.
let toneDetectionThreshold: Float = 0.01

print("PlugInput — Phase 0 routing spike")
print(String(repeating: "=", count: 60))

// MARK: - 1. Microphone permission

heading("1. Microphone permission")

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    print("  authorized")
case .notDetermined:
    print("  not determined — requesting…")
    let gate = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { result in
        granted = result
        gate.signal()
    }
    gate.wait()
    print(granted ? "  granted" : "  DENIED")
case .denied, .restricted:
    print("  DENIED — grant your terminal app Microphone access in")
    print("  System Settings > Privacy & Security > Microphone, then re-run.")
@unknown default:
    print("  unknown authorization state")
}

// MARK: - 2. Device inventory

heading("2. Devices")

let allDevices: [AudioDevice]
do {
    allDevices = try DeviceEnumerator.allDevices()
} catch {
    fail("could not enumerate devices: \(error)")
}

for device in allDevices {
    print("  \(device.summary)")
}

// MARK: - 3. Selection

heading("3. Selection")

let inputDevice: AudioDevice
let monitorDevice: AudioDevice
do {
    inputDevice = try DeviceEnumerator.defaultInputDevice()
    monitorDevice = try DeviceEnumerator.defaultOutputDevice()
} catch {
    fail("could not read default devices: \(error)")
}

guard let virtualDevice = allDevices.first(where: {
    $0.name.localizedCaseInsensitiveContains(virtualDeviceFragment) && $0.hasOutput
}) else {
    fail("""
    no device matching "\(virtualDeviceFragment)" found.
    Install it with:  brew install blackhole-2ch
    """)
}

guard inputDevice.hasInput else {
    fail("default input device \"\(inputDevice.name)\" reports no input channels")
}
guard virtualDevice.uid != monitorDevice.uid else {
    fail("""
    system output is currently set to \(monitorDevice.name).
    Set your system output back to speakers/headphones — routing into the virtual
    device from both sides would feed back.
    """)
}

print("  input  : \(inputDevice.summary)")
print("  monitor: \(monitorDevice.summary)")
print("  virtual: \(virtualDevice.summary)")

// MARK: - Direct mode (aggregate control)

if mode == .direct {
    heading("Direct — tone into \(virtualDevice.name), no aggregate")

    let emitter = DirectToneEmitter(deviceID: virtualDevice.id)
    do {
        try emitter.start()
    } catch {
        fail("could not emit into \(virtualDevice.name): \(error)")
    }

    print("  emitting for \(Int(runSeconds))s")
    let emitStartedAt = Date()
    let emitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
            if Date().timeIntervalSince(emitStartedAt) >= runSeconds {
                emitter.stop()
                print("  done")
                exit(0)
            }
            print(String(format: "\r  rendered tone: %6.1f dBFS", dbfsOf(emitter.renderedPeak)), terminator: "")
            fflush(stdout)
        }
    }
    RunLoop.main.add(emitTimer, forMode: .common)
    RunLoop.main.run()
}

// MARK: - Listener mode

// Listener mode never builds an aggregate — it deliberately behaves like any ordinary app
// selecting BlackHole as its microphone, which is exactly the claim under test.
if mode == .listen {
    // A third argument overrides the device, so the listener itself can be validated against
    // a source known to carry signal (the built-in mic). Without that check, "silence" is
    // ambiguous between "device is silent" and "capture is not running at all".
    let requestedTarget = arguments.dropFirst(2).first
    let listenTarget = requestedTarget
        .flatMap { fragment in
            allDevices.first { $0.name.localizedCaseInsensitiveContains(fragment) && $0.hasInput }
        } ?? virtualDevice

    heading("Listener — standing in for Zoom/Discord/OBS")
    print("  opening \(listenTarget.name) as a microphone in this separate process")

    let listener = VirtualDeviceListener(deviceID: listenTarget.id)
    do {
        try listener.start()
    } catch {
        fail("could not open \(virtualDevice.name): \(error)")
    }

    print("  listening for \(Int(runSeconds))s\n")

    let listenStartedAt = Date()
    let listenTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        MainActor.assumeIsolated {
            let tone = listener.toneLevels
            if Date().timeIntervalSince(listenStartedAt) >= runSeconds {
                listener.stop()
                print("\n")
                print(String(format: "  broadband peak    : %.1f dBFS", dbfsOf(listener.currentPeak)))
                print(String(format: "  peak 440Hz energy : %.1f dBFS", dbfsOf(tone.peak)))
                // The control run (nothing routing) establishes the floor; the tone sits far
                // above it. A broadband threshold would pass on noise alone — it already did
                // once during this spike.
                let passed = tone.peak > toneDetectionThreshold
                print("")
                print(passed
                    ? "RESULT: PASS — a separate process read the 440Hz tone from \(virtualDevice.name) while the aggregate held it"
                    : "RESULT: FAIL — no 440Hz tone on \(virtualDevice.name) (threshold \(String(format: "%.1f", dbfsOf(toneDetectionThreshold))) dBFS)")
                exit(passed ? 0 : 2)
            }

            let filled = Int((min(tone.current * 4, 1) * 40).rounded())
            let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: 40 - filled)
            print(String(format: "\r  440Hz [\(bar)] %6.1f dBFS  (broadband %5.1f)",
                         dbfsOf(tone.current), dbfsOf(listener.currentPeak)), terminator: "")
            fflush(stdout)
        }
    }
    RunLoop.main.add(listenTimer, forMode: .common)
    RunLoop.main.run()
}

// The aggregate carries each distinct device once, in this order. Channel offsets follow
// the same order, which is what the channel maps in PassthroughEngine depend on.
var orderedSubDevices: [AudioDevice] = []
for device in [inputDevice, virtualDevice, monitorDevice]
where !orderedSubDevices.contains(where: { $0.uid == device.uid }) {
    orderedSubDevices.append(device)
}

if orderedSubDevices.count < 3 {
    print("  note: monitor and input are the same device — 2-subdevice aggregate")
}

// MARK: - 4. Aggregate

heading("4. Aggregate device")

let aggregate: AggregateDevice
do {
    aggregate = try AggregateDevice(
        uid: "com.pluginput.spike.aggregate",
        name: "PlugInput Spike",
        subDevices: orderedSubDevices,
        clockSourceUID: inputDevice.uid
    )
} catch {
    fail("could not create aggregate: \(error)")
}

// Every exit path must reach this or the user is left with an orphaned device.
// The registry is deliberately reachable from outside the main actor, which `atexit` is.
atexit { AggregateRegistry.destroyAll() }

print("  created id \(aggregate.id) [\(aggregate.uid)]")
print("  subdevices: \(orderedSubDevices.map { $0.name }.joined(separator: " + "))")
print("  clock master: \(inputDevice.name)")

do {
    let reported = try aggregate.reportedChannelCounts()
    let computed = aggregate.layout
    print("  channels reported: in \(reported.input), out \(reported.output)")
    print("  channels computed: in \(computed.totalInputChannels), out \(computed.totalOutputChannels)")
    if reported.input != computed.totalInputChannels || reported.output != computed.totalOutputChannels {
        print("  WARNING: computed layout disagrees with CoreAudio — channel maps may be wrong")
    }
    print("  input offsets : \(computed.inputOffsets)")
    print("  output offsets: \(computed.outputOffsets)")
} catch {
    print("  could not read aggregate channel counts: \(error)")
}

do {
    let range = try BufferSize.range(aggregate.id)
    try BufferSize.set(max(128, range.lowerBound), on: aggregate.id)
    let actual = try BufferSize.current(aggregate.id)
    let latencyMs = Double(actual) / 48_000 * 1000
    print("  buffer: \(actual) frames (range \(range.lowerBound)…\(range.upperBound)) ≈ \(String(format: "%.1f", latencyMs)) ms")
} catch {
    print("  buffer size not settable: \(error)")
}

// MARK: - 5. Engine

heading("5. Passthrough engine")

let passthrough = PassthroughEngine(
    aggregate: aggregate,
    inputUID: inputDevice.uid,
    monitorUID: monitorDevice.uid,
    virtualUID: virtualDevice.uid
)

do {
    try passthrough.start(source: mode == .tone ? .tone : .microphone)
} catch {
    fail("could not start engine: \(error)")
}

print("  running")

// MARK: - 6. Verify

heading("6. Verify")
print("""
  You should hear yourself in \(monitorDevice.name).

  While this runs, confirm the virtual side:
    open -a "QuickTime Player"
    File > New Audio Recording > select "\(virtualDevice.name)" as the source
    Speak — the level meter should move.

  Running for \(Int(runSeconds))s. Ctrl-C to stop early.
""")
print(String(repeating: "-", count: 60))

let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
// Both handlers below are scheduled on the main queue/runloop, so the isolation they need
// already holds — `assumeIsolated` states that to the compiler without hopping.
signalSource.setEventHandler {
    MainActor.assumeIsolated {
        print("\n\ninterrupted")
        passthrough.stop()
    }
    AggregateRegistry.destroyAll()
    exit(0)
}
signalSource.resume()

let startedAt = Date()
let meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    MainActor.assumeIsolated {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed < runSeconds else {
            print("\n\ncomplete")
            passthrough.stop()
            AggregateRegistry.destroyAll()
            exit(0)
        }

        let peak = passthrough.currentPeak
        let filled = Int((min(peak, 1) * 40).rounded())
        let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: 40 - filled)
        let dbfs = peak > 0 ? 20 * log10(peak) : -Float.infinity
        let label = dbfs.isFinite ? String(format: "%6.1f dBFS", dbfs) : "  -inf dBFS"
        print("\r  input [\(bar)] \(label)", terminator: "")
        fflush(stdout)
    }
}
RunLoop.main.add(meterTimer, forMode: .common)
RunLoop.main.run()
