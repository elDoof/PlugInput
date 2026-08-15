import AVFoundation
import CoreAudio
import Foundation

/// Emits the probe tone straight into one device, with no aggregate and no channel maps.
///
/// This is the control for the aggregate. If a separate process can hear this tone on
/// BlackHole but cannot hear the same tone routed through the aggregate, then concurrent
/// access to BlackHole is fine and the aggregate is what breaks — which points the design at
/// the ring-buffer fallback rather than at abandoning the virtual-device approach.
final class DirectToneEmitter: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let deviceID: AudioObjectID
    private var toneGenerator: ToneGenerator?

    private let peakLock = NSLock()
    private var renderedPeakLevel: Float = 0

    /// Peak of the most recently rendered tone buffer, so callers can distinguish
    /// "never rendered" from "rendered but not delivered to the device".
    var renderedPeak: Float {
        peakLock.lock()
        defer { peakLock.unlock() }
        return renderedPeakLevel
    }

    init(deviceID: AudioObjectID) {
        self.deviceID = deviceID
    }

    func start() throws {
        // Output only: this process emits and never captures, and touching `inputNode` would
        // make AVAudioEngine build a capture chain on the same device for no reason.
        try EngineDeviceBinding.bind(deviceID: deviceID, on: engine, sides: .output)

        let deviceFormat = engine.outputNode.inputFormat(forBus: 0)
        let mixer = engine.mainMixerNode

        let tone = ToneGenerator(sampleRate: deviceFormat.sampleRate)
        toneGenerator = tone
        engine.attach(tone.node)
        engine.connect(tone.node, to: mixer, format: tone.format)
        engine.connect(mixer, to: engine.outputNode, format: deviceFormat)

        // Prove the node is actually being pulled. Without this, "no signal downstream" is
        // ambiguous between "not rendering" and "rendering but not delivered".
        tone.node.installTap(onBus: 0, bufferSize: 1024, format: tone.format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[frame])) }
            self.peakLock.lock()
            self.renderedPeakLevel = peak
            self.peakLock.unlock()
        }

        let beforeStart = EngineDeviceBinding.currentDevice(of: engine.outputNode.audioUnit)

        engine.prepare()
        try engine.start()

        // Read the binding back *after* start. Verifying only before start would miss the
        // engine reverting to the system default while preparing, which would silently send
        // this tone to the speakers instead of the virtual device.
        let afterStart = EngineDeviceBinding.currentDevice(of: engine.outputNode.audioUnit)
        print("  output device before start: \(beforeStart.map(String.init) ?? "unknown")")
        print("  output device after start : \(afterStart.map(String.init) ?? "unknown")  (target \(deviceID))")
        if afterStart != deviceID {
            print("  >>> ENGINE REVERTED THE DEVICE — tone is not going to the target <<<")
        }

        print("  emitting 440Hz directly into device \(deviceID) at \(describe(deviceFormat))")
    }

    func stop() {
        engine.stop()
    }

    private func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount)ch @ \(Int(format.sampleRate))Hz"
    }
}
