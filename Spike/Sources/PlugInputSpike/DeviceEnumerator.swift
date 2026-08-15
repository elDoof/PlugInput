import CoreAudio
import Foundation

/// An immutable snapshot of one CoreAudio device.
///
/// `id` is valid only while the device stays attached; `uid` is the stable identifier and
/// is what aggregate descriptions and saved preferences must key on.
struct AudioDevice: Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var hasInput: Bool { inputChannels > 0 }
    var hasOutput: Bool { outputChannels > 0 }

    var summary: String {
        "\(name)  in:\(inputChannels) out:\(outputChannels)  [\(uid)]"
    }
}

enum DeviceEnumerator {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func allDevices() throws -> [AudioDevice] {
        let ids = try propertyArray(
            systemObject,
            address(kAudioHardwarePropertyDevices),
            of: AudioObjectID.self
        )
        // A device can vanish between the ID read and the describe call, and some virtual
        // devices refuse individual properties. Skipping those beats aborting enumeration.
        return ids.compactMap { try? describe($0) }
    }

    static func describe(_ id: AudioObjectID) throws -> AudioDevice {
        AudioDevice(
            id: id,
            uid: try propertyString(id, address(kAudioDevicePropertyDeviceUID)),
            name: try propertyString(id, address(kAudioObjectPropertyName)),
            inputChannels: try channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: try channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    static func defaultInputDevice() throws -> AudioDevice {
        try describe(try defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice))
    }

    static func defaultOutputDevice() throws -> AudioDevice {
        try describe(try defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice))
    }

    static func device(uid: String) throws -> AudioDevice? {
        try allDevices().first { $0.uid == uid }
    }

    static func device(nameContaining fragment: String) throws -> AudioDevice? {
        try allDevices().first { $0.name.localizedCaseInsensitiveContains(fragment) }
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        try propertyValue(systemObject, address(selector), initial: AudioObjectID(0))
    }
}

/// Reads and writes the hardware buffer size, which sets the floor on round-trip latency.
enum BufferSize {
    static func current(_ deviceID: AudioObjectID) throws -> UInt32 {
        try propertyValue(deviceID, address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0))
    }

    /// The device may clamp the request to its supported range, so callers should read
    /// `current` back afterwards rather than assume the request stuck.
    static func set(_ frames: UInt32, on deviceID: AudioObjectID) throws {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), pointer
            )
        }
        try checkStatus(status, "AudioObjectSetPropertyData(bufferFrameSize=\(frames))")
    }

    static func range(_ deviceID: AudioObjectID) throws -> ClosedRange<UInt32> {
        let value = try propertyValue(
            deviceID,
            address(kAudioDevicePropertyBufferFrameSizeRange),
            initial: AudioValueRange(mMinimum: 0, mMaximum: 0)
        )
        return UInt32(value.mMinimum)...UInt32(value.mMaximum)
    }
}
