import Foundation

/// One window of the meeting app, as the capture side sees it.
public struct WindowInfo: Equatable, Sendable {
    public let id: UInt32
    public let title: String
    public let width: Double
    public let height: Double
    public init(id: UInt32, title: String, width: Double, height: Double) {
        self.id = id; self.title = title; self.width = width; self.height = height
    }
}

/// Which of the meeting app's windows is the call. In a browser it must be the call's own tab: Lyra never reads
/// Gmail in a window beside it. Elsewhere it prefers the meeting window (Zoom's "Zoom Meeting", not its home window).
public enum CallWindowRule {
    static let browsers = ["Google Chrome", "Microsoft Edge", "Brave", "Arc", "Safari", "Firefox"]
    /// Whole words in a browser tab's title that mean a call ("Meet - abc-defg-hij", "Microsoft Teams").
    private static let callSites = ["meet", "teams", "zoom", "webex", "whereby", "jitsi", "around", "gather"]
    /// Words in a desktop app's window title that mark its call window over its other windows.
    private static let callWindows = ["meeting", "webinar", "call", "huddle"]
    private static let minWidth = 200.0
    private static let minHeight = 150.0

    public static func isBrowser(_ appName: String) -> Bool {
        browsers.contains { appName == $0 || appName.hasPrefix($0 + " ") }
    }

    /// The call's window, or nil (a browser with no call tab in front of any window, or nothing big enough).
    /// `startTitle` is the meeting's title at Allow; a window still showing it wins.
    public static func pick(_ windows: [WindowInfo], appName: String, startTitle: String) -> WindowInfo? {
        let big = windows.filter { $0.width >= minWidth && $0.height >= minHeight }
        let start = startTitle.trimmingCharacters(in: .whitespaces)
        let showsStart: (WindowInfo) -> Bool = { start.count >= 4 && start != appName && $0.title.contains(start) }
        let largest: ([WindowInfo]) -> WindowInfo? = { $0.max { $0.width * $0.height < $1.width * $1.height } }
        if isBrowser(appName) {
            return largest(big.filter(showsStart)) ?? largest(big.filter { hasWord($0.title, callSites) })
        }
        return largest(big.filter(showsStart)) ?? largest(big.filter { hasWord($0.title, callWindows) }) ?? largest(big)
    }

    private static func hasWord(_ title: String, _ words: [String]) -> Bool {
        let tokens = Set(title.lowercased().split { !$0.isLetter })
        return words.contains { tokens.contains(Substring($0)) }
    }
}

/// Seconds on the recording's own timeline: since recording began, less any time paused. Transcript times count
/// recorded audio only, so tile and slide times line up with them.
public struct RecordingClock: Sendable {
    private let now: @Sendable () -> TimeInterval
    private let start: TimeInterval
    private var pausedAt: TimeInterval?
    private var pausedTotal: TimeInterval = 0

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        start = now()
    }

    public var seconds: Double { (pausedAt ?? now()) - start - pausedTotal }

    public mutating func pause() { if pausedAt == nil { pausedAt = now() } }

    public mutating func resume() {
        guard let pausedAt else { return }
        pausedTotal += now() - pausedAt
        self.pausedAt = nil
    }
}
