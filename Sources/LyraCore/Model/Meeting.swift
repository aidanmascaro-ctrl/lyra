import Foundation

public enum TrackKind: String, Codable, Sendable { case meeting, mic }

public struct Meeting: Codable, Sendable {
    public let id: UUID
    public var title: String
    public let appName: String
    public let bundleID: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var warnings: [String]
    /// Each track's level and error, saved at stop so crash recovery can still spot a silent meeting track.
    public var tracks: [TrackResult]? = nil
    /// SHA-256 hex of the note's transcript section as Lyra last wrote it; a different section means Aidan edited it.
    public var transcriptSectionHash: String? = nil
    /// SHA-256 of each grey (Claude) block's `NoteMarkdown.render([block])` as last written, to tell edited blocks from untouched ones.
    public var expandedHashes: [String]? = nil
    public var seriesSuggestion: String? = nil
    public var seriesRejected: Bool? = nil
    public var screenText: [String]? = nil
    /// Where the note was last seen; a hint only, the lyra_id in the note is the identity.
    public var notePath: String? = nil
    /// When the latest recording began in a note that existed before it (New note, or recording again after End);
    /// nil when recording made the note.
    public var recordingStartedAt: Date? = nil
    /// Finished parts filed under `parts/1…N` when recording was resumed after End; nil for one part.
    public var earlierParts: Int? = nil
    /// Seconds recorded in those earlier parts: where the latest part starts on the note's timeline.
    public var recordedBefore: Double? = nil
    /// Why the after-meeting title/tags call failed, for the UI; nil once it succeeds.
    public var insightsError: String? = nil
    /// Why expanding the notes failed, for the UI's Retry; nil once it succeeds.
    public var expandError: String? = nil
    /// True once Claude's title/tags call has succeeded, so a re-run never replaces a title Aidan edited.
    public var insightsDone: Bool? = nil
    /// True once the after-meeting step (title, tags, expansion) has finished; the launch sweep skips these.
    public var afterMeetingDone: Bool? = nil

    public init(id: UUID = UUID(), title: String, appName: String, bundleID: String? = nil,
                startedAt: Date, endedAt: Date? = nil, warnings: [String] = []) {
        self.id = id; self.title = title; self.appName = appName; self.bundleID = bundleID
        self.startedAt = startedAt; self.endedAt = endedAt; self.warnings = warnings
    }

    /// A meeting title from the app's window name. When the app is a browser, its own suffix
    /// (" - Google Chrome", with or without a trailing " - <Profile>") is dropped; nothing left means the app name.
    public static func title(window: String?, appName: String) -> String {
        var title = window ?? ""
        // Only the meeting app's own suffix: " - Arc - " inside a Safari title is part of the title.
        let browsers = ["Google Chrome", "Microsoft Edge", "Brave", "Arc", "Safari"].filter { appName == $0 || appName.hasPrefix($0 + " ") }  // "Brave Browser"
        search: for browser in browsers {
            for dash in [" - ", " – ", " — "] {
                if title.hasSuffix(dash + browser) {
                    title.removeLast((dash + browser).count)
                } else if let r = title.range(of: dash + browser + dash, options: .backwards) {
                    title = String(title[..<r.lowerBound])
                } else { continue }
                break search
            }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? appName : title
    }
}
