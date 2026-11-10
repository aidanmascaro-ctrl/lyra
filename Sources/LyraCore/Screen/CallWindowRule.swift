import Foundation

/// One window of the meeting app, as the capture side sees it.
public struct WindowInfo: Equatable, Sendable {
    public let id: UInt32
    public let title: String
    public let width: Double
    public let height: Double
    /// On this desktop and not minimised.
    public let isOnScreen: Bool
    public init(id: UInt32, title: String, width: Double, height: Double, isOnScreen: Bool = true) {
        self.id = id; self.title = title; self.width = width; self.height = height; self.isOnScreen = isOnScreen
    }
}

/// Which of the meeting app's windows is the call. Deny by default: a window is watched only when its title says it
/// is the call. In a browser that is the call site's own tab title, so Gmail or a "Your Zoom receipt" email beside
/// it is never read. A desktop app's call window is the one titled as a meeting or call (Zoom's "Zoom Meeting", not
/// its home window; never WhatsApp's chat list). FaceTime is all call, so its largest window is.
public enum CallWindowRule {
    static let browsers = ["Google Chrome", "Microsoft Edge", "Brave", "Arc", "Safari", "Firefox", "Vivaldi", "Opera",
                           "Chromium", "Dia", "Orion", "Zen"]
    /// How call sites title their tab: a prefix, or a phrase anywhere ("Meet - abc-defg-hij", "Sync | Microsoft Teams").
    private static let callTabPrefixes = ["Meet - ", "Meet – ", "Meet: ", "Zoom - ", "Zoom – ", "Webex - ", "Webex – ",
                                          "Whereby", "Jitsi Meet"]
    private static let callTabPhrases = ["Google Meet", "Microsoft Teams", "| Teams", "Zoom Meeting", "Zoom Webinar",
                                         "Webex Meeting", "Jitsi Meet"]
    /// Words in a desktop app's window title that mark its call window over its other windows.
    private static let callWindows = ["meeting", "webinar", "call", "huddle"]
    /// Apps whose every window is the call.
    private static let callOnlyApps = ["FaceTime"]
    private static let minWidth = 200.0
    private static let minHeight = 150.0

    public static func isBrowser(_ appName: String) -> Bool {
        browsers.contains { appName == $0 || appName.hasPrefix($0 + " ") }
    }

    /// The call's window, or nil: a browser with no call tab in front of any window, an app with no window titled as
    /// a call, or nothing big enough. `startTitle` (the meeting's title at Allow) only chooses between call windows:
    /// it may itself be another tab's title. A call window on this desktop wins over one that isn't (full screen on its
    /// own desktop, or minimised).
    public static func pick(_ windows: [WindowInfo], appName: String, startTitle: String) -> WindowInfo? {
        let big = windows.filter { $0.width >= minWidth && $0.height >= minHeight }
        let start = startTitle.trimmingCharacters(in: .whitespaces)
        let largest: ([WindowInfo]) -> WindowInfo? = { $0.max { $0.width * $0.height < $1.width * $1.height } }
        let calls: [WindowInfo]
        if isBrowser(appName) { calls = big.filter { isCallTab($0.title) } }
        else if callOnlyApps.contains(appName) { calls = big }
        else { calls = big.filter { hasWord($0.title, callWindows) } }
        let shown = calls.filter(\.isOnScreen)
        return best(shown.isEmpty ? calls : shown, appName: appName, start: start, largest: largest)
    }

    private static func best(_ calls: [WindowInfo], appName: String, start: String,
                             largest: ([WindowInfo]) -> WindowInfo?) -> WindowInfo? {
        largest(calls.filter { start.count >= 4 && start != appName && $0.title.contains(start) }) ?? largest(calls)
    }

    private static func isCallTab(_ title: String) -> Bool {
        callTabPrefixes.contains { title.hasPrefix($0) } || callTabPhrases.contains { title.contains($0) }
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
