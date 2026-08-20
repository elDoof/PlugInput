import CoreAudio
import Foundation

/// An immutable snapshot of one CoreAudio device.
///
/// `id` is valid only while the device stays attached; `uid` is the stable identifier and
/// is what aggregate descriptions and saved preferences must key on.
public struct AudioDevice: Equatable, Sendable, Identifiable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    public var summary: String {
        "\(name)  in:\(inputChannels) out:\(outputChannels)  [\(uid)]"
    }
}

public enum DeviceEnumerator {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    public static func allDevices() throws -> [AudioDevice] {
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

    public static func defaultInputDevice() throws -> AudioDevice {
        try describe(try defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice))
    }

    public static func defaultOutputDevice() throws -> AudioDevice {
        try describe(try defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice))
    }

    public static func device(uid: String) throws -> AudioDevice? {
        try allDevices().first { $0.uid == uid }
    }

    /// Points the system's default input at a specific device.
    ///
    /// Needed because installing a loopback driver tends to *make* it the default input: macOS
    /// elects a newly appeared device, and the installer restarts `coreaudiod`, which is a
    /// common trigger for that election. The user is then left with everything that follows the
    /// system default — Zoom, Ableton, anything — listening to a loopback carrying silence, with
    /// nothing to indicate why. Setting it back needs no privileges, but it is a change to a
    /// system-wide setting, so it happens only when the user explicitly asks for it.
    public static func setDefaultInputDevice(_ deviceID: AudioObjectID) throws {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var value = deviceID
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                systemObject, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), pointer
            )
        }
        try checkStatus(status, "AudioObjectSetPropertyData(defaultInputDevice=\(deviceID))")
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        try propertyValue(systemObject, address(selector), initial: AudioObjectID(0))
    }
}

/// Reads a device's nominal sample rate.
///
/// Read-only on purpose. Writing it would drag the user's hardware to a rate chosen by this
/// app, which is the mistake gotcha #24 is about — the app follows the device, never the
/// reverse. What this is *for* is catching the engine running its graph at a different rate
/// than the hardware, which produces silence rather than an error.
enum SampleRate {
    static func current(_ deviceID: AudioObjectID) throws -> Double {
        try propertyValue(deviceID, address(kAudioDevicePropertyNominalSampleRate), initial: Double(0))
    }
}

/// Reads and writes the hardware buffer size, which sets the floor on round-trip latency.
enum BufferSize {
    static func current(_ deviceID: AudioObjectID) throws -> UInt32 {
        try propertyValue(deviceID, address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0))
    }

    // There is deliberately no setter here any more.
    //
    // Writing this property on the engine's aggregate reached straight through to its
    // subdevices — the user's own interface among them — and re-sized the buffer underneath
    // whatever else was using it, which a DAW on that interface hears as crackle and dropouts.
    // Nothing restored the old value afterwards, so it outlived the session. The app now reads
    // whatever the aggregate inherits and logs it; see
    // `AudioEngineController.logBufferSize(of:)`. Latency is not the constraint here — gotcha #9
    // measured the floor at 15 frames — so there was never much to win and a lot to break.

    static func range(_ deviceID: AudioObjectID) throws -> ClosedRange<UInt32> {
        let value = try propertyValue(
            deviceID,
            address(kAudioDevicePropertyBufferFrameSizeRange),
            initial: AudioValueRange(mMinimum: 0, mMaximum: 0)
        )
        return UInt32(value.mMinimum)...UInt32(value.mMaximum)
    }
}
