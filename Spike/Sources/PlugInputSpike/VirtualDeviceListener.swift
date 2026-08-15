import AVFoundation
import CoreAudio
import Foundation

/// Reads a single device's input, standing in for Zoom / Discord / OBS.
///
/// This exists to answer the one question the whole plan rests on: can a *separate process*
/// open BlackHole as a microphone while our aggregate holds it as a subdevice? Running it as
/// its own process is essential — proving it inside the routing process would prove nothing.
/// `@unchecked Sendable` is an explicit contract, not a shortcut: every mutable field below
/// is guarded by `levelLock`, and `engine` is only started or stopped from the main actor.
/// The realtime tap touches nothing else.
final class VirtualDeviceListener: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let deviceID: AudioObjectID

    /// The frequency `ToneGenerator` emits. Measuring this specific bin rather than
    /// broadband level is what separates our signal from whatever noise floor the virtual
    /// device happens to carry.
    static let probeFrequency: Double = 440

    private let levelLock = NSLock()
    private var peakLevel: Float = 0
    private var toneMagnitude: Float = 0
    private var maxToneMagnitude: Float = 0
    private var sawSignal = false

    init(deviceID: AudioObjectID) {
        self.deviceID = deviceID
    }

    func start() throws {
        // Input only. Binding the output side too is wrong for a capture-only engine: for a
        // device with no output channels it fails outright, and on a duplex device it
        // disturbs the capture chain into delivering zero-filled buffers — which reads
        // exactly like "the device is silent" and sent this spike chasing the wrong bug.
        try EngineDeviceBinding.bind(deviceID: deviceID, on: engine, sides: .input)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw SpikeError.message("listener input format is \(inputFormat) — device not readable")
        }

        // Assert rather than assume: reading the wrong device is silent and looks plausible.
        let boundInput = EngineDeviceBinding.currentDevice(of: inputNode.audioUnit)
        guard boundInput == deviceID else {
            throw SpikeError.message(
                "input node is on device \(boundInput.map(String.init) ?? "unknown"), expected \(deviceID)"
            )
        }
        print("  listening on device \(deviceID): \(inputFormat.channelCount)ch @ \(Int(inputFormat.sampleRate))Hz")

        // Deliberately NO output connection. Touching `mainMixerNode` wires this process
        // back out to the same device, and since that device is BlackHole the result is a
        // self-loop: the listener hears itself and reports signal even with nothing routing.
        // That produced a false PASS on the first run of this spike.
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            var peak: Float = 0
            for frame in 0..<frames {
                peak = max(peak, abs(channel[frame]))
            }
            let tone = Self.goertzelMagnitude(
                samples: channel,
                frameCount: frames,
                targetFrequency: Self.probeFrequency,
                sampleRate: inputFormat.sampleRate
            )

            self.levelLock.lock()
            self.peakLevel = peak
            self.toneMagnitude = tone
            self.maxToneMagnitude = max(self.maxToneMagnitude, tone)
            if peak > 0.001 { self.sawSignal = true }
            self.levelLock.unlock()
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    var currentPeak: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return peakLevel
    }

    /// True once any buffer exceeded the noise floor. Broadband only — not a pass signal
    /// on its own, because the virtual device carries a noise floor of its own.
    var didReceiveSignal: Bool {
        levelLock.lock()
        defer { levelLock.unlock() }
        return sawSignal
    }

    /// Energy in the 440Hz bin for the most recent buffer, and the run's maximum.
    /// The maximum is the figure that decides pass/fail.
    var toneLevels: (current: Float, peak: Float) {
        levelLock.lock()
        defer { levelLock.unlock() }
        return (toneMagnitude, maxToneMagnitude)
    }

    /// Goertzel single-bin DFT — the cheap way to ask "is *this* frequency present?".
    ///
    /// A broadband peak cannot distinguish our tone from the device's noise floor; this can.
    private static func goertzelMagnitude(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        targetFrequency: Double,
        sampleRate: Double
    ) -> Float {
        let k = (Double(frameCount) * targetFrequency / sampleRate).rounded()
        let omega = 2 * Double.pi * k / Double(frameCount)
        let coefficient = 2 * cos(omega)

        var current = 0.0
        var previous = 0.0
        for frame in 0..<frameCount {
            let next = Double(samples[frame]) + coefficient * current - previous
            previous = current
            current = next
        }

        let power = current * current + previous * previous - coefficient * current * previous
        // Normalise so a full-scale sine at the target frequency reads ~1.0.
        return Float(sqrt(max(power, 0)) / (Double(frameCount) / 2))
    }
}
