import AppKit
import CoreAudio
import Darwin
import LyraCore

/// Lists processes that currently have an input stream running, via Core Audio process objects.
public final class CoreAudioMicUsage: MicUsageProvider {
    public init() {}

    public func currentMicUsers() -> [MicUser] {
        CoreAudioObject.processObjects().compactMap { object -> MicUser? in
            guard CoreAudioObject.scalar(object, kAudioProcessPropertyIsRunningInput) == UInt32(1),
                  let pid: pid_t = CoreAudioObject.scalar(object, kAudioProcessPropertyPID),
                  !SystemService.isBackground(executablePath: Self.executablePath(of: pid)) else { return nil }
            return MicUser(pid: pid, bundleID: CoreAudioObject.string(object, kAudioProcessPropertyBundleID) ?? "", appName: appName(for: pid))
        }
    }

    /// The GUI app that owns `pid`, following the helper -> parent chain (Chrome's audio helper -> Chrome).
    public static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            current = parent(of: current)
        }
        return nil
    }

    /// Owning GUI app's name, else the process's own name, else its executable name.
    private func appName(for pid: pid_t) -> String {
        if let name = Self.owningApp(of: pid)?.localizedName { return name }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buf = [CChar](repeating: 0, count: 256)
        let n = Int(proc_name(pid, &buf, UInt32(buf.count)))
        return n > 0 ? String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self) : "pid \(pid)"
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = Int(proc_pidpath(pid, &buf, UInt32(buf.count)))
        return n > 0 ? String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n > 0 ? pid_t(info.pbi_ppid) : 0
    }
}
