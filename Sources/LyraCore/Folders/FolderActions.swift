import Foundation

/// Filing meetings into sidebar folders and taking folders away. Only the note's file moves (its name, and so its
/// `[[links]]`, stay the same unless a clash adds ` (n)`); its series is kept. Nothing is ever deleted.
public enum FolderActions {
    /// Files the note in `folder`, or takes it out of folders when nil (back to its series folder, or `Meetings/`).
    /// A series that came only from the folder the note sat in is written to `series:` first, so the move keeps it.
    public static func move(_ loaded: LoadedNote, to folder: String?, index: NoteIndex) throws -> SeriesOutcome {
        let series = SeriesActions.currentSeries(of: loaded, index: index)
        let destination = try destination(folder, series: series, index: index)
        if sameDirectory(loaded.url.deletingLastPathComponent(), destination) { return SeriesOutcome(note: loaded, problems: []) }

        let kept = try keep(series, in: loaded, index: index)
        let moved = try index.move(kept, into: destination)
        var problems = SeriesActions.linkProblems(moved.skippedLinkFiles)
        if let series { problems += SeriesActions.writePage(series, index: index) }
        return SeriesOutcome(note: moved.note, problems: problems)
    }

    /// Moves every Lyra note out of the folder, then puts the folder in the Trash if only its marker is left.
    /// Anything else in it (a file Aidan put there in Obsidian) keeps the folder where it is. Returns plain-English
    /// problems, empty when all went well. Tests pass their own `trash` so nothing real is moved.
    public static func remove(_ name: String, index: NoteIndex,
                              trash: (URL) throws -> Void = MeetingTrash.systemTrash) throws -> [String] {
        let folders = MeetingFolders(index: index)
        let folder = folders.url(of: name)
        guard folders.isFolder(folder) else { throw MeetingFoldersError.missingFolder(name) }
        let problems = moveNotesOut(of: folder, index: index)
        return problems + trashIfEmpty(folder, name: name, trash: trash)
    }

    // MARK: Helpers

    /// Files Finder may leave in any folder; they never keep a folder from going to the Trash.
    private static let ignorable: Set<String> = [MeetingFolders.markerName, ".DS_Store"]

    private static func destination(_ folder: String?, series: String?, index: NoteIndex) throws -> URL {
        guard let folder else { return NoteIndex.seriesFolder(series, under: index.notesRoot) }
        let folders = MeetingFolders(index: index)
        let url = folders.url(of: folder)
        guard folders.isFolder(url) else { throw MeetingFoldersError.missingFolder(folder) }
        return url
    }

    private static func keep(_ series: String?, in loaded: LoadedNote, index: NoteIndex) throws -> LoadedNote {
        guard let series, loaded.document.front.series != series else { return loaded }
        return try index.update(loaded) { $0.front.series = series }
    }

    private static func moveNotesOut(of folder: URL, index: NoteIndex) -> [String] {
        index.allNotes()
            .filter { sameDirectory($0.url.deletingLastPathComponent(), folder) }
            .flatMap { note -> [String] in
                do { return try move(note, to: nil, index: index).problems } catch {
                    return ["Lyra couldn't move “\(note.document.front.title)” out of the folder: \(error.localizedDescription)"]
                }
            }
    }

    /// Checked and trashed under the write lock, so nothing can be filed into the folder in between.
    private static func trashIfEmpty(_ folder: URL, name: String, trash: (URL) throws -> Void) -> [String] {
        NoteIndex.withWriteLock {
            let contents: [String]
            do { contents = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch {
                // Never taken for empty: what Lyra can't see might be Aidan's.
                return ["Lyra moved the meetings out of “\(name)” but couldn't look inside the folder to check it was empty, "
                        + "so it left the folder where it is: \(error.localizedDescription)"]
            }
            let left = contents.filter { !ignorable.contains($0) }.sorted()
            guard left.isEmpty else {
                return ["Lyra moved the meetings out of “\(name)” but left the folder where it is, because it still holds: "
                        + left.joined(separator: ", ")]
            }
            do { try trash(folder); return [] } catch {
                return ["Lyra moved the meetings out of “\(name)” but couldn't put the folder in the Trash: \(error.localizedDescription)"]
            }
        }
    }

    private static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        NoteIndex.samePath(a.resolvingSymlinksInPath(), b.resolvingSymlinksInPath())
    }
}
