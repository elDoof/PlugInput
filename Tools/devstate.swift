import CoreAudio
import Foundation

// Reads the state a leaked StartIO would show: the device claiming to be running with no client.
func devices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var out: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &out) == noErr else { return "" }
    return out as String
}

func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PlugInput"
for id in devices() where string(id, kAudioObjectPropertyName) == target {
    let running = uint32(id, kAudioDevicePropertyDeviceIsRunning)
    let runningSelf = uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere)
    print("device      : \(target) (id \(id))")
    print("uid         : \(string(id, kAudioDevicePropertyDeviceUID))")
    print("IsRunning   : \(running.map(String.init) ?? "unreadable")   <- 1 with no app running means StartIO leaked")
    print("RunningSomewhere: \(runningSelf.map(String.init) ?? "unreadable")")
}
