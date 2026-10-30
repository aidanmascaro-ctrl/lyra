import Foundation

/// What a series change did, with anything Lyra couldn't finish in plain English (the change itself happened).
public struct SeriesOutcome: Sendable {
    public let note: LoadedNote
    public let problems: [String]
}

/// Aidan's series choices: join, move or leave a series, rename one, retitle a meeting. Every move keeps
/// `[[links]]` pointing at the note and rewrites the series pages it touches.
public enum SeriesActions {
    /// Sets `series:` (nil leaves the series), moves the note into that series' folder, and rewrites the
    /// pages of the series it left and joined.
    public static func move(_ loaded: LoadedNote, to series: String?, index: NoteIndex) throws -> SeriesOutcome {
        let old = currentSeries(of: loaded, index: index)
        let saved = try index.update(loaded) { $0.front.series = series }
        let moved = try index.relocateReportingSkips(saved, title: saved.document.front.title, series: series)
        var problems = linkProblems(moved.skippedLinkFiles)
        for name in Set([old, series].compactMap { $0 }) { problems += writePage(name, index: index) }
        return SeriesOutcome(note: moved.note, problems: problems)
    }

    /// "Not related": the suggestion isn't shown again for this meeting.
    public static func reject(meetingFolder: URL) throws {
        try AfterMeeting.updateMeeting(in: meetingFolder) { $0.seriesRejected = true }
    }

    /// Renames the series folder (and the notes' `series:`), then rewrites its page under the new name.
    public static func rename(_ from: String, to: String, index: NoteIndex) throws -> [String] {
        let name = to.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != from else { return [] }
        let skipped = try index.renameSeriesFolder(from: from, to: name)
        var problems: [String] = []
        if !skipped.isEmpty {
            problems.append("Lyra renamed the series but couldn't update: " + skipped.map(\.lastPathComponent).joined(separator: ", "))
        }
        return problems + writePage(name, index: index)
    }

    /// A new title, and the file renamed to match, in the series folder it is in.
    public static func retitle(_ loaded: LoadedNote, to title: String, index: NoteIndex) throws -> SeriesOutcome {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != loaded.document.front.title else { return SeriesOutcome(note: loaded, problems: []) }
        let series = currentSeries(of: loaded, index: index)
        let saved = try index.update(loaded) { $0.front.title = title }
        let moved = try index.relocateReportingSkips(saved, title: title, series: series)
        let problems = linkProblems(moved.skippedLinkFiles) + (series.map { writePage($0, index: index) } ?? [])
        return SeriesOutcome(note: moved.note, problems: problems)
    }

    /// The series the note is in now (its folder counts, as in the home window).
    public static func currentSeries(of note: LoadedNote, index: NoteIndex) -> String? {
        SeriesLibrary.summaries(notes: [note], meetingsByID: [:], notesRoot: index.notesRoot).first?.series
    }

    static func writePage(_ name: String, index: NoteIndex) -> [String] {
        do { try SeriesLibrary.writeSeriesPage(name: name, index: index); return [] } catch {
            return [error.localizedDescription]
        }
    }

    static func linkProblems(_ skipped: [URL]) -> [String] {
        skipped.isEmpty ? [] : ["Lyra moved the note but couldn't update links to it in: " + skipped.map(\.lastPathComponent).joined(separator: ", ")]
    }
}
