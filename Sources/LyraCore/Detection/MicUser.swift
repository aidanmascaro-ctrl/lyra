import Foundation

/// A process currently using the microphone. `bundleID` is "" when the process has none.
public struct MicUser: Hashable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let appName: String

    public init(pid: pid_t, bundleID: String, appName: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
    }
}

public protocol MicUsageProvider: Sendable {
    func currentMicUsers() -> [MicUser]
}
