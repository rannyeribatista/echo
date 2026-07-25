import CoreAudio
import Foundation

// Core Audio plumbing for the tap engine — carried over from the validated
// spike (spikes/proc-tap-ducker, results in docs/desktop-design.md): error
// type, property helpers, HAL process enumeration, default output device.

struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String {
        "\(context) failed: OSStatus \(status) ('\(fourCC(UInt32(bitPattern: status)))')"
    }
}

func fourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
    return String(value)
}

func check(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else { throw CAError(status: status, context: context) }
}

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getPropertyDataSize(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> UInt32 {
    var addr = addr
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size),
              "GetPropertyDataSize \(fourCC(addr.mSelector))")
    return size
}

func getPOD<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) throws -> T {
    var addr = addr
    var value = initial
    var size = UInt32(MemoryLayout<T>.stride)
    try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value),
              "GetPropertyData \(fourCC(addr.mSelector))")
    return value
}

func getObjectIDList(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
    let size = try getPropertyDataSize(objectID, addr)
    let count = Int(size) / MemoryLayout<AudioObjectID>.stride
    guard count > 0 else { return [] }
    var addr = addr
    var list = [AudioObjectID](repeating: 0, count: count)
    var mutableSize = size
    try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &mutableSize, &list),
              "GetPropertyData \(fourCC(addr.mSelector))")
    return list
}

func getString(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
    var addr = addr
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
    try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value),
              "GetPropertyData \(fourCC(addr.mSelector))")
    return value?.takeRetainedValue() as String? ?? ""
}

// MARK: - Process objects

/// One process registered with the audio HAL. Spike finding: only processes
/// actually brokering audio appear here (Chrome shows 3 objects, not 50), so
/// "tap everything with IsRunningOutput" needs no helper-hunting.
struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
}

func listAudioProcesses() throws -> [AudioProcessInfo] {
    let ids = try getObjectIDList(AudioObjectID(kAudioObjectSystemObject),
                                  address(kAudioHardwarePropertyProcessObjectList))
    return ids.map { oid in
        AudioProcessInfo(
            objectID: oid,
            pid: (try? getPOD(oid, address(kAudioProcessPropertyPID), pid_t(0))) ?? -1,
            bundleID: (try? getString(oid, address(kAudioProcessPropertyBundleID))) ?? "",
            isRunningOutput: ((try? getPOD(oid, address(kAudioProcessPropertyIsRunningOutput),
                                           UInt32(0))) ?? 0) != 0)
    }
}

func defaultOutputDevice() throws -> (id: AudioDeviceID, uid: String, sampleRate: Double) {
    let devID = try getPOD(AudioObjectID(kAudioObjectSystemObject),
                           address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0))
    let uid = try getString(devID, address(kAudioDevicePropertyDeviceUID))
    let rate = (try? getPOD(devID, address(kAudioDevicePropertyNominalSampleRate), Double(0))) ?? 0
    return (devID, uid, rate)
}
