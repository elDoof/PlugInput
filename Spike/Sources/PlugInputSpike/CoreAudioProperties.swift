import CoreAudio
import Foundation

/// Thin, throwing wrappers over the `AudioObjectGetPropertyData` family.
///
/// CoreAudio's C API forces the same six-line dance for every read. These helpers
/// collapse it so the device and aggregate code reads as intent, not ceremony.
enum CoreAudioError: Error, CustomStringConvertible {
    case status(OSStatus, context: String)

    var description: String {
        switch self {
        case let .status(code, context):
            return "\(context) failed: OSStatus \(code) (\(Self.fourCharCode(code)))"
        }
    }

    /// Most CoreAudio error codes are packed four-character codes; render them readably.
    private static func fourCharCode(_ code: OSStatus) -> String {
        let value = UInt32(bitPattern: code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "non-printable" }
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
}

func checkStatus(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError.status(status, context: context()) }
}

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func propertyDataSize(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> UInt32 {
    var addr = addr
    var size: UInt32 = 0
    try checkStatus(
        AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(\(addr.mSelector))"
    )
    return size
}

func propertyValue<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, initial: T) throws -> T {
    var addr = addr
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, pointer)
    }
    try checkStatus(status, "AudioObjectGetPropertyData(\(addr.mSelector))")
    return value
}

func propertyArray<T: BinaryInteger>(
    _ objectID: AudioObjectID,
    _ addr: AudioObjectPropertyAddress,
    of type: T.Type
) throws -> [T] {
    let byteSize = try propertyDataSize(objectID, addr)
    let count = Int(byteSize) / MemoryLayout<T>.size
    guard count > 0 else { return [] }

    var addr = addr
    var size = byteSize
    var buffer = [T](repeating: 0, count: count)
    // `count > 0` is guaranteed above, so the buffer is non-empty and has a base address.
    let status = buffer.withUnsafeMutableBytes { raw in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw.baseAddress!)
    }
    try checkStatus(status, "AudioObjectGetPropertyData(array \(addr.mSelector))")
    return buffer
}

/// CoreAudio hands back a +1 retained `CFString`, so the result must be consumed as
/// `takeRetainedValue` — bridging a bare `CFString` out of the call leaks it.
func propertyString(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
    var addr = addr
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, pointer)
    }
    try checkStatus(status, "AudioObjectGetPropertyData(string \(addr.mSelector))")
    guard let value else { return "" }
    return value.takeRetainedValue() as String
}

/// Sums the channels across every buffer in a device's stream configuration.
///
/// Channel count is not a scalar property — it must be derived from the
/// `AudioBufferList` returned by `kAudioDevicePropertyStreamConfiguration`,
/// which is variable-length and therefore needs a raw allocation.
func channelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
    let addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    let byteSize = try propertyDataSize(deviceID, addr)
    guard byteSize > 0 else { return 0 }

    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(byteSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }

    var mutableAddr = addr
    var size = byteSize
    try checkStatus(
        AudioObjectGetPropertyData(deviceID, &mutableAddr, 0, nil, &size, raw),
        "AudioObjectGetPropertyData(streamConfiguration)"
    )

    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}
