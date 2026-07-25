import CoreAudio
import Foundation

// MARK: - Errors / helpers

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

struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let isRunningOutput: Bool
    let isRunning: Bool
}

func processName(pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return "?" }
    return withUnsafePointer(to: &info.kp_proc.p_comm) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
            String(cString: $0)
        }
    }
}

func listAudioProcesses() throws -> [AudioProcessInfo] {
    let ids = try getObjectIDList(AudioObjectID(kAudioObjectSystemObject),
                                  address(kAudioHardwarePropertyProcessObjectList))
    return ids.compactMap { oid in
        let pid = (try? getPOD(oid, address(kAudioProcessPropertyPID), pid_t(0))) ?? -1
        let bundleID = (try? getString(oid, address(kAudioProcessPropertyBundleID))) ?? ""
        let runningOutput = ((try? getPOD(oid, address(kAudioProcessPropertyIsRunningOutput), UInt32(0))) ?? 0) != 0
        let running = ((try? getPOD(oid, address(kAudioProcessPropertyIsRunning), UInt32(0))) ?? 0) != 0
        return AudioProcessInfo(objectID: oid, pid: pid, bundleID: bundleID,
                                name: pid > 0 ? processName(pid: pid) : "?",
                                isRunningOutput: runningOutput, isRunning: running)
    }
}

/// Match by case-insensitive substring against bundle ID or process name.
func matchProcesses(query: String, in processes: [AudioProcessInfo]) -> [AudioProcessInfo] {
    let q = query.lowercased()
    return processes.filter {
        $0.bundleID.lowercased().contains(q) || $0.name.lowercased().contains(q)
    }
}

func listTaps() throws -> [AudioObjectID] {
    try getObjectIDList(AudioObjectID(kAudioObjectSystemObject),
                        address(kAudioHardwarePropertyTapList))
}

func defaultOutputDevice() throws -> (id: AudioDeviceID, uid: String, name: String, sampleRate: Double) {
    let devID = try getPOD(AudioObjectID(kAudioObjectSystemObject),
                           address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0))
    let uid = try getString(devID, address(kAudioDevicePropertyDeviceUID))
    let name = (try? getString(devID, address(kAudioObjectPropertyName))) ?? "?"
    let rate = (try? getPOD(devID, address(kAudioDevicePropertyNominalSampleRate), Double(0))) ?? 0
    return (devID, uid, name, rate)
}

// MARK: - Timing

let machTimebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

@inline(__always) func machToMs(_ delta: UInt64) -> Double {
    Double(delta) * Double(machTimebase.numer) / Double(machTimebase.denom) / 1_000_000.0
}

@inline(__always) func nowMach() -> UInt64 { mach_absolute_time() }
