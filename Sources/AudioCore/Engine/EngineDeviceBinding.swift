import AVFoundation
import CoreAudio
import Foundation

/// Points an `AVAudioEngine` at a specific CoreAudio device.
///
/// Setting `kAudioOutputUnitProperty_CurrentDevice` on the output node alone is *not*
/// enough. The input node keeps reading the system default input, and because that still
/// produces plausible-looking audio, the mistake does not announce itself — it shows up as
/// a device that reports the wrong channel count and a "noise floor" on a digital loopback.
/// That cost this spike three misleading test runs, so both sides are bound here together.
enum EngineDeviceBinding {
    /// Which half of the engine to point at the device.
    ///
    /// Output-only matters: merely *accessing* `engine.inputNode` makes AVAudioEngine
    /// configure a capture chain, so a pure emitter should never touch it.
    struct Sides: OptionSet {
        let rawValue: Int
        static let input = Sides(rawValue: 1 << 0)
        static let output = Sides(rawValue: 1 << 1)
        static let both: Sides = [.input, .output]
    }

    static func bind(deviceID: AudioObjectID, on engine: AVAudioEngine, sides: Sides = .both) throws {
        if sides.contains(.output) {
            try apply(deviceID, to: engine.outputNode.audioUnit, label: "output node")
        }
        if sides.contains(.input) {
            try apply(deviceID, to: engine.inputNode.audioUnit, label: "input node")
        }
    }

    private static func apply(_ deviceID: AudioObjectID, to unit: AudioUnit?, label: String) throws {
        guard let unit else {
            throw AudioCoreError.message("\(label) has no underlying audio unit")
        }
        var device = deviceID
        try checkStatus(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "AudioUnitSetProperty(CurrentDevice = \(deviceID)) on \(label)"
        )
    }

    /// Reads back which device a node is actually on, so callers can assert rather than hope.
    static func currentDevice(of unit: AudioUnit?) -> AudioObjectID? {
        guard let unit else { return nil }
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            &size
        )
        return status == noErr ? device : nil
    }
}
