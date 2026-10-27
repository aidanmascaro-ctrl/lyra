import Foundation

public struct MeetingSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var date: Date
    public var series: String?
    public var tags: [String]
    public var summary: String?
    /// Claude's guess at a series, only while Aidan hasn't confirmed or rejected it.
    public var suggestion: String?
    /// The meeting's recordings folder, nil when Lyra has no record of the meeting.
    public var folder: URL?
    public var note: URL

    public init(id: UUID, title: String, date: Date, series: String?, tags: [String], summary: String?,
                suggestion: String?, folder: URL?, note: URL) {
        self.id = id; self.title = title; self.date = date; self.series = series; self.tags = tags
        self.summary = summary; self.suggestion = suggestion; self.folder = folder; self.note = note
    }
}

public struct SeriesGroup: Equatable, Sendable {
    public let name: String
    /// Newest first.
    public var meetings: [MeetingSummary]
    /// The three tags shared by the most meetings.
    public var tags: [String]
}

public enum SeriesLibrary {
    private static let tagLimit = 3

    /// One summary per note. A note sitting in `notesRoot/<X>/` belongs to series X even if its header says otherwise,
    /// because moving a note into a series folder in Obsidian counts as joining that series.
    public static func summaries(notes: [LoadedNote], meetingsByID: [UUID: (Meeting, URL)], notesRoot: URL) -> [MeetingSummary] {
        notes.map { note in
            let front = note.document.front
            let known = meetingsByID[front.lyraID]
            let series = folderSeries(of: note.url, under: notesRoot, frontmatter: front.series) ?? front.series
            let suggestion = series == nil && known?.0.seriesRejected != true ? known?.0.seriesSuggestion : nil
            return MeetingSummary(id: front.lyraID, title: front.title, date: front.date, series: series, tags: front.tags,
                                  summary: front.summary, suggestion: suggestion, folder: known?.1, note: note.url)
        }
    }

    public static func groups(_ s: [MeetingSummary]) -> [SeriesGroup] {
        let bySeries = Dictionary(grouping: s.filter { $0.series != nil }, by: { $0.series! })
        return bySeries.map { name, meetings in
            let newestFirst = meetings.sorted { $0.date > $1.date }
            return SeriesGroup(name: name, meetings: newestFirst, tags: topTags(of: newestFirst))
        }
        .sorted { ($0.meetings[0].date, $1.name) > ($1.meetings[0].date, $0.name) }
    }

    public static func pendingSuggestions(_ s: [MeetingSummary]) -> [MeetingSummary] {
        s.filter { $0.series == nil && $0.suggestion != nil }.sorted { $0.date > $1.date }
    }

    /// The page Lyra owns for a series: a link to each meeting with one short line, oldest first.
    /// `notesRoot` is where the page lives; links are by note name, so Obsidian finds notes wherever they are.
    public static func seriesPage(name: String, meetings: [MeetingSummary], notesRoot: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.timeZone = .current
        formatter.dateFormat = "d MMM yyyy"
        let lines = meetings.sorted { $0.date < $1.date }.map { meeting -> String in
            let target = meeting.note.deletingPathExtension().lastPathComponent
            var line = "- [[\(target)|\(oneLine(meeting.title))]] — \(formatter.string(from: meeting.date))"
            if let summary = meeting.summary.map(oneLine), !summary.isEmpty { line += " — \(summary)" }
            return line + "\n"
        }
        return "---\nlyra_series: true\n---\n# \(oneLine(name))\n\n" + lines.joined()
    }

    /// Writes `notesRoot/<name>/<name>.md` from the series' current meetings; leaves the file alone when nothing changed.
    public static func writeSeriesPage(name: String, index: NoteIndex) throws {
        let folderName = MeetingPaths.sanitise(name)
        guard !folderName.isEmpty else { throw NoteIndexError.seriesFolderMissing(name) }
        let members = summaries(notes: index.allNotes(), meetingsByID: [:], notesRoot: index.notesRoot).filter { $0.series == name }
        let page = seriesPage(name: name, meetings: members, notesRoot: index.notesRoot)

        let folder = index.notesRoot.appendingPathComponent(folderName, isDirectory: true)
        let url = folder.appendingPathComponent(folderName + ".md")
        if FileManager.default.fileExists(atPath: url.path) {
            // Never replace a note Aidan wrote by hand that happens to share the series' name.
            guard let existing = try? String(contentsOf: url, encoding: .utf8), isSeriesPage(existing) else {
                throw NoteIndexError.notASeriesPage(name)
            }
            if existing == page { return }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NoteIndex.writeAtomically(Data(page.utf8), to: url, mayCreate: true)
    }

    // MARK: Helpers

    /// The series folder name when the note's parent is a direct child of `root` and isn't just the sanitised frontmatter series.
    private static func folderSeries(of note: URL, under root: URL, frontmatter: String?) -> String? {
        let parent = note.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else { return nil }
        let folder = parent.lastPathComponent
        if let frontmatter, MeetingPaths.sanitise(frontmatter).caseInsensitiveCompare(folder) == .orderedSame { return nil }
        return folder
    }

    static func isSeriesPage(_ text: String) -> Bool {
        guard text.hasPrefix("---\n"), let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { return false }
        return text[..<close.lowerBound].split(separator: "\n").contains("lyra_series: true")
    }

    private static func topTags(of meetings: [MeetingSummary]) -> [String] {
        let counts = meetings.flatMap { Set($0.tags) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(tagLimit).map(\.key)
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
