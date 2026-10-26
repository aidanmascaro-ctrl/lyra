import AppKit
import CoreAudio
import Darwin
import LyraCore

/// Lists processes that currently have an input stream running, via Core Audio process objects.
public final class CoreAudioMicUsage: MicUsageProvider {
    public init() {}

    public func currentMicUsers() -> [MicUser] {
        processObjects().compactMap { object -> MicUser? in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1,
                  let pid: pid_t = scalar(object, kAudioProcessPropertyPID) else { return nil }
            return MicUser(pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID) ?? "", appName: appName(for: pid))
        }
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func scalar<T: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        scalar(object, selector)
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    /// Owning GUI app's name (helper -> parent chain), else the process's own name, else its executable name.
    private func appName(for pid: pid_t) -> String {
        var current = pid
        for _ in 0..<8 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular, let name = app.localizedName {
                return name
            }
            current = parent(of: current)
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buf = [CChar](repeating: 0, count: 256)
        let n = Int(proc_name(pid, &buf, UInt32(buf.count)))
        return n > 0 ? String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self) : "pid \(pid)"
    }

    private func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n > 0 ? pid_t(info.pbi_ppid) : 0
    }
}
