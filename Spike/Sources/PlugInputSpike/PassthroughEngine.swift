import AVFoundation
import CoreAudio
import Foundation

/// Runs `AVAudioEngine` on the private aggregate, passing the mic straight through to both
/// the monitor output and the virtual device.
///
/// Two channel maps do the real work here:
///
/// - The **input** map selects only the microphone's channel. This is not cosmetic: the
///   aggregate also exposes BlackHole's *input* channels, which carry whatever we just
///   wrote to BlackHole's output. Passing those through would close a feedback loop.
/// - The **output** map fans our stereo bus into both the BlackHole pair and the monitor
///   pair, so you hear yourself and other apps see the same signal.
///
/// Every step is attempted defensively and reported, because the exact scope/element that
/// `kAudioOutputUnitProperty_ChannelMap` wants is the part of this design most likely to
/// need adjusting against a real device.
final class PassthroughEngine {
    private let engine = AVAudioEngine()
    private let aggregate: AggregateDevice
    private let inputUID: String
    private let monitorUID: String
    private let virtualUID: String

    private let levelLock = NSLock()
    private var peakLevel: Float = 0

    /// Held so the source node outlives `start()`; the engine only holds it weakly enough
    /// that dropping our reference would silence the graph.
    private var toneGenerator: ToneGenerator?

    /// What feeds the chain. The tone exists so the virtual-device leg can be verified
    /// without depending on someone speaking into a microphone at the right moment.
    enum Source {
        case microphone
        case tone
    }

    init(aggregate: AggregateDevice, inputUID: String, monitorUID: String, virtualUID: String) {
        self.aggregate = aggregate
        self.inputUID = inputUID
        self.monitorUID = monitorUID
        self.virtualUID = virtualUID
    }

    // MARK: - Lifecycle

    func start(source: Source) throws {
        try bindAggregateDevice()
        try applyInputChannelMap()
        try applyOutputChannelMap()

        // Drive the whole graph at the device's own rate. Left to itself the main mixer
        // defaults to 44.1kHz, which would insert a pointless resample between a 48kHz
        // input and a 48kHz output.
        let deviceFormat = engine.outputNode.inputFormat(forBus: 0)
        let mixer = engine.mainMixerNode

        switch source {
        case .microphone:
            try connectMicrophone(to: mixer)
        case .tone:
            connectTone(to: mixer, sampleRate: deviceFormat.sampleRate)
        }

        engine.connect(mixer, to: engine.outputNode, format: deviceFormat)

        engine.prepare()
        try engine.start()

        // Re-apply after start. AVAudioEngine sets stream formats on the output unit while
        // preparing, and that discards any channel map configured beforehand — which is why
        // the first version of this spike routed nothing to the virtual device.
        print("  re-applying output channel map after start:")
        try applyOutputChannelMap()
        try verifyOutputChannelMap()

        // Report the settled graph, not the lazily-created defaults.
        print("  mixer format      : \(describe(mixer.outputFormat(forBus: 0)))")
        print("  output node format: \(describe(engine.outputNode.outputFormat(forBus: 0)))")
    }

    private func connectMicrophone(to mixer: AVAudioMixerNode) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("  input node format : \(describe(inputFormat))")

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw SpikeError.message(
                """
                Input node reports \(inputFormat.channelCount)ch @ \(inputFormat.sampleRate)Hz.
                A zero format almost always means microphone permission was denied to the
                process running this binary. Grant your terminal app Microphone access in
                System Settings > Privacy & Security > Microphone, then re-run.
                """
            )
        }

        engine.connect(inputNode, to: mixer, format: inputFormat)
        installLevelTap(on: inputNode, format: inputFormat)
    }

    private func connectTone(to mixer: AVAudioMixerNode, sampleRate: Double) {
        let tone = ToneGenerator(sampleRate: sampleRate)
        toneGenerator = tone
        engine.attach(tone.node)
        engine.connect(tone.node, to: mixer, format: tone.format)
        print("  source            : 440Hz tone @ \(Int(sampleRate))Hz")
        installLevelTap(on: tone.node, format: tone.format)
    }

    func stop() {
        if let tone = toneGenerator {
            tone.node.removeTap(onBus: 0)
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }

    /// Peak level of the most recent input buffer, in the range 0...1.
    var currentPeak: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return peakLevel
    }

    // MARK: - Device binding

    private func bindAggregateDevice() throws {
        try EngineDeviceBinding.bind(deviceID: aggregate.id, on: engine)

        let boundInput = EngineDeviceBinding.currentDevice(of: engine.inputNode.audioUnit)
        let boundOutput = EngineDeviceBinding.currentDevice(of: engine.outputNode.audioUnit)
        print("  bound input node  : device \(boundInput.map(String.init) ?? "unknown")")
        print("  bound output node : device \(boundOutput.map(String.init) ?? "unknown")")
        guard boundInput == aggregate.id, boundOutput == aggregate.id else {
            throw SpikeError.message("engine did not bind to aggregate \(aggregate.id)")
        }
    }

    // MARK: - Channel maps

    /// Selects just the microphone channel out of the aggregate's combined input list.
    private func applyInputChannelMap() throws {
        guard let inputOffset = aggregate.layout.inputOffsets[inputUID] else {
            throw SpikeError.message("input device \(inputUID) is not in the aggregate")
        }
        var map: [Int32] = [Int32(inputOffset)]
        let byteSize = UInt32(MemoryLayout<Int32>.size * map.count)

        guard let inputUnit = engine.inputNode.audioUnit else {
            throw SpikeError.message("input node has no underlying audio unit")
        }

        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            1,
            &map,
            byteSize
        )
        if status == noErr {
            print("  input channel map : \(map) (device input ch \(inputOffset) -> mono bus)")
        } else {
            print("  input channel map : FAILED OSStatus \(status) — mic channel not isolated")
            print("                      feedback risk: BlackHole's inputs may pass through")
        }
    }

    /// Fans the stereo bus into the BlackHole pair and the monitor pair.
    private func applyOutputChannelMap() throws {
        let total = aggregate.layout.totalOutputChannels
        guard total > 0 else { throw SpikeError.message("aggregate reports no output channels") }

        var map = [Int32](repeating: -1, count: total)
        for uid in [virtualUID, monitorUID] {
            guard let offset = aggregate.layout.outputOffsets[uid] else { continue }
            if offset < total { map[offset] = 0 }
            if offset + 1 < total { map[offset + 1] = 1 }
        }

        guard let outputUnit = engine.outputNode.audioUnit else {
            throw SpikeError.message("output node has no underlying audio unit")
        }
        let byteSize = UInt32(MemoryLayout<Int32>.size * total)

        // The documented scope for the output element varies between references; try the
        // documented one first and fall back, reporting whichever the device accepted.
        let attempts: [(scope: AudioUnitScope, label: String)] = [
            (kAudioUnitScope_Output, "output scope"),
            (kAudioUnitScope_Input, "input scope"),
        ]

        for attempt in attempts {
            let status = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_ChannelMap,
                attempt.scope,
                0,
                &map,
                byteSize
            )
            if status == noErr {
                print("  output channel map: \(map) via \(attempt.label)")
                return
            }
            print("  output channel map: \(attempt.label) rejected (OSStatus \(status))")
        }

        print("  output channel map: NOT APPLIED — monitor pair will likely be silent")
    }

    /// Reads the channel map back off the unit.
    ///
    /// Setting a CoreAudio property can return `noErr` and still not stick once the engine
    /// reconfigures around it, so the write is not evidence — only the read-back is.
    private func verifyOutputChannelMap() throws {
        guard let outputUnit = engine.outputNode.audioUnit else { return }

        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = AudioUnitGetPropertyInfo(
            outputUnit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            0,
            &size,
            &writable
        )
        guard infoStatus == noErr, size > 0 else {
            print("  channel map readback: unavailable (OSStatus \(infoStatus))")
            return
        }

        var readBack = [Int32](repeating: -2, count: Int(size) / MemoryLayout<Int32>.size)
        let status = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            0,
            &readBack,
            &size
        )
        if status == noErr {
            print("  channel map readback: \(readBack)")
        } else {
            print("  channel map readback: failed (OSStatus \(status))")
        }
    }

    // MARK: - Metering

    private func installLevelTap(on node: AVAudioNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channel[frame]))
            }
            self.levelLock.lock()
            self.peakLevel = peak
            self.levelLock.unlock()
        }
    }

    private func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount)ch @ \(Int(format.sampleRate))Hz"
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(text): return text
        }
    }
}
