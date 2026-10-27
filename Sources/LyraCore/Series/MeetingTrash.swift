import Foundation

/// Moves a meeting to the Mac's Trash: its Obsidian note and its recordings folder, then tidies the series it was in.
/// Nothing is deleted; Finder's Put Back restores either one.
public enum MeetingTrash {
    /// The real Trash. Tests pass their own closure so nothing real is ever moved.
    public static let systemTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Trashes whatever of the meeting exists and returns plain-English problems (empty when all went well).
    /// The note goes first: it is what Aidan sees, and if it can't be moved the recordings are left alone.
    public static func trash(id: UUID, folder: URL?, index: NoteIndex,
                             trash: (URL) throws -> Void = systemTrash) -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        var series: String?

        if let note = try? index.load(id, hint: nil) {
            series = SeriesActions.currentSeries(of: note, index: index)
            do { try trash(note.url) } catch {
                return ["Lyra couldn't move the note to the Trash, so it left the recordings where they are: \(error.localizedDescription)"]
            }
        } else {
            problems.append("Lyra couldn't find this meeting's note in Obsidian; it may already be moved or deleted.")
        }

        if let folder {
            if fm.fileExists(atPath: folder.path) {
                do { try trash(folder) } catch {
                    problems.append("Lyra couldn't move the recordings folder to the Trash: \(error.localizedDescription)")
                }
            } else if problems.isEmpty {
                problems.append("The recordings folder was already gone, so only the note went to the Trash.")
            }
        }

        if let series { problems += tidy(series: series, index: index, trash: trash) }
        return problems
    }

    /// Rewrites the series page; a series with no meetings left has its page and (empty) folder trashed instead.
    private static func tidy(series: String, index: NoteIndex, trash: (URL) throws -> Void) -> [String] {
        let remaining = SeriesLibrary.summaries(notes: index.allNotes(), meetingsByID: [:], notesRoot: index.notesRoot)
            .contains { $0.series == series }
        do {
            if remaining { try SeriesLibrary.writeSeriesPage(name: series, index: index) } else { try trashEmptySeries(series, index: index, trash: trash) }
            return []
        } catch {
            return [error.localizedDescription]
        }
    }

    private static func trashEmptySeries(_ series: String, index: NoteIndex, trash: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let name = MeetingPaths.sanitise(series)
        guard !name.isEmpty else { return }
        let folder = index.notesRoot.appendingPathComponent(name, isDirectory: true)
        let page = folder.appendingPathComponent(name + ".md")
        // Only Lyra's own page: a note Aidan wrote that shares the name stays, and so does its folder.
        if let text = try? String(contentsOf: page, encoding: .utf8), SeriesLibrary.isSeriesPage(text) { try trash(page) }
        let left = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        if left.isEmpty, fm.fileExists(atPath: folder.path) { try trash(folder) }
    }
}
