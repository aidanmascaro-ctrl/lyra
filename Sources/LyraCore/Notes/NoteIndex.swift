import Foundation
import CryptoKit

/// A note as it was read from disk. `fingerprint` is what `save` compares against to notice an edit made elsewhere.
public struct LoadedNote: Sendable {
    public let url: URL
    public let document: NoteDocument
    /// SHA-256 of the file's bytes.
    public let fingerprint: String
}

public enum NoteIndexError: Error, Equatable, LocalizedError {
    case notFound(UUID)
    case changedOnDisk(URL)
    case seriesFolderMissing(String)
    case seriesFolderExists(String)
    case notASeriesPage(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Lyra couldn't find this meeting's note in the Meetings folder."
        case .changedOnDisk: "This note was changed in Obsidian since Lyra opened it, so Lyra didn't save over it."
        case .seriesFolderMissing(let name): "Lyra couldn't find a series folder called “\(name)”."
        case .seriesFolderExists(let name): "There is already a series folder called “\(name)”, so Lyra didn't rename into it."
        case .notASeriesPage(let name): "There's already a note called “\(name)” in that series folder, so Lyra didn't replace it with the series page."
        }
    }
}

/// What `relocateReportingSkips` did, including the files whose `[[links]]` it could not update.
public struct Relocation: Sendable {
    public let note: LoadedNote
    public let skippedLinkFiles: [URL]
}

/// Finds Lyra's notes by `lyra_id` (Aidan may have moved or renamed them in Obsidian), saves them without ever
/// overwriting an edit made elsewhere, and renames/moves them while keeping `[[links]]` pointing at them.
/// Nothing is cached between calls.
///
/// Every write and move holds one process-wide lock (`withWriteLock`): the editor saves on the main actor while the
/// after-meeting step writes in the background, and a read→compare→write must not interleave with another write or
/// a move. Reads don't take it (writes are atomic swaps). Locked sections are synchronous and never take it again.
public struct NoteIndex: Sendable {
    public let notesRoot: URL
    public let vaultRoot: URL

    /// Frontmatter sits at the top of a note; only this many lines are read when scanning.
    private static let scanLineLimit = 40
    private static let scanByteLimit = 16 * 1024
    static let saveAttempts = 3
    private static let writeLock = NSLock()
    /// Tests only: called for each file the link scan reads, outside the write lock.
    var linkScanProbe: (@Sendable (URL) -> Void)?

    public init(notesRoot: URL, vaultRoot: URL) {
        self.notesRoot = notesRoot
        self.vaultRoot = vaultRoot
    }

    // MARK: Find and load

    public func find(_ id: UUID, hint: URL?) -> URL? {
        if let hint, Self.frontmatterID(of: hint) == id { return hint }
        return markdownFiles(under: notesRoot).first { Self.frontmatterID(of: $0) == id }
    }

    public func load(_ id: UUID, hint: URL?) throws -> LoadedNote {
        guard let url = find(id, hint: hint) else { throw NoteIndexError.notFound(id) }
        return try read(url)
    }

    public func allNotes() -> [LoadedNote] {
        markdownFiles(under: notesRoot)
            .filter { Self.frontmatterID(of: $0) != nil }
            .sorted { $0.path < $1.path }
            .compactMap { try? read($0) }
    }

    // MARK: Save

    public func save(_ document: NoteDocument, over loaded: LoadedNote) throws -> LoadedNote {
        try Self.withWriteLock { try saveLocked(document, over: loaded) }
    }

    /// Applies `change` to the note as it is on disk and saves it. If the file changed or moved in between (Aidan
    /// typing in Obsidian, a stale `loaded`), reloads and applies `change` again, so only the parts `change` touches
    /// are Lyra's. `change` runs under the write lock: it may only edit the document, never call NoteIndex.
    public func update(_ loaded: LoadedNote, _ change: (inout NoteDocument) -> Void) throws -> LoadedNote {
        try Self.withWriteLock {
            var current = loaded
            for attempt in 1...Self.saveAttempts {
                var document = current.document
                change(&document)
                if document == current.document { return current }
                do { return try saveLocked(document, over: current) } catch where attempt < Self.saveAttempts && Self.isChangedOrMoved(error) {
                    current = try load(current.document.front.lyraID, hint: current.url)
                }
            }
            preconditionFailure("the last attempt returns or throws")
        }
    }

    /// The caller holds the write lock.
    private func saveLocked(_ document: NoteDocument, over loaded: LoadedNote) throws -> LoadedNote {
        let current = try Data(contentsOf: loaded.url)
        guard Self.fingerprint(of: current) == loaded.fingerprint else { throw NoteIndexError.changedOnDisk(loaded.url) }
        let data = Data(document.render().utf8)
        try Self.writeAtomically(data, to: loaded.url)
        return LoadedNote(url: loaded.url, document: document, fingerprint: Self.fingerprint(of: data))
    }

    /// The note changed since it was loaded, or isn't where it was (renamed, moved, trashed): find it again by `lyra_id`.
    static func isChangedOrMoved(_ error: Error) -> Bool {
        if case NoteIndexError.changedOnDisk = error { return true }
        let code = (error as? CocoaError)?.code
        return code == .fileReadNoSuchFile || code == .fileNoSuchFile
    }

    /// Runs `body` holding the lock every note write and move takes. `body` must be synchronous and must not call
    /// anything that takes the lock again (`save`, `update`, `relocate…`, `move`, `renameSeriesFolder`, `MeetingFolders`): it isn't reentrant.
    static func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        try writeLock.withLock(body)
    }

    /// Tests only: nobody (this thread included) holds the write lock right now.
    static var writeLockIsFree: Bool {
        guard writeLock.try() else { return false }
        writeLock.unlock()
        return true
    }

    // MARK: Rename and move

    /// Moves the note to `notesRoot/<series>/<date — title>.md` and points `[[links]]` at the new name.
    public func relocate(_ loaded: LoadedNote, title: String, series: String?) throws -> LoadedNote {
        try relocateReportingSkips(loaded, title: title, series: series).note
    }

    /// The move holds the write lock; the vault-wide `[[link]]` rewrite runs after it, locking one file at a time.
    public func relocateReportingSkips(_ loaded: LoadedNote, title: String, series: String?) throws -> Relocation {
        withLinksRewritten(try Self.withWriteLock { try relocateLocked(loaded, title: title, series: series) })
    }

    /// A note filed in a sidebar folder stays there whatever its title or series; otherwise it goes to its series folder.
    private func relocateLocked(_ loaded: LoadedNote, title: String, series: String?) throws -> Move {
        let filed = MeetingFolders.folderName(of: loaded.url, under: notesRoot)
        let folder = filed.map { notesRoot.appendingPathComponent($0, isDirectory: true) } ?? Self.seriesFolder(series, under: notesRoot)
        return try moveLocked(loaded, into: folder, base: Self.noteBaseName(title: title, date: loaded.document.front.date))
    }

    /// Moves the note into `folder` keeping its file name (` (n)` added on a clash) and points `[[links]]` at it.
    /// Used for sidebar folders: nothing in the note changes.
    public func move(_ loaded: LoadedNote, into folder: URL) throws -> Relocation {
        let base = loaded.url.deletingPathExtension().lastPathComponent
        return withLinksRewritten(try Self.withWriteLock { try moveLocked(loaded, into: folder, base: base) })
    }

    /// A finished move: the note where it is now, and the file name its `[[links]]` still have to follow.
    private struct Move {
        let note: LoadedNote
        let oldName: String
    }

    private func withLinksRewritten(_ move: Move) -> Relocation {
        let newName = move.note.url.deletingPathExtension().lastPathComponent
        return Relocation(note: move.note, skippedLinkFiles: rewriteLinks(from: move.oldName, to: newName))
    }

    /// The caller holds the write lock. Links are left for `withLinksRewritten`, after the lock.
    private func moveLocked(_ loaded: LoadedNote, into folder: URL, base: String) throws -> Move {
        let fm = FileManager.default
        let oldName = loaded.url.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(base + ".md")
        if Self.samePath(target, loaded.url) { return Move(note: loaded, oldName: oldName) }
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) (\(n)).md")
            if Self.samePath(target, loaded.url) { return Move(note: loaded, oldName: oldName) }
            n += 1
        }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.moveItem(at: loaded.url, to: target)
        NoteImages.moveEmbedded(loaded.document, from: loaded.url, to: target)
        return Move(note: try read(target), oldName: oldName)
    }

    /// Renames the series: its folder (when there is one), `series:` in every Lyra note of the series wherever it is
    /// filed (sidebar folders included), and the series page and its links. A series whose meetings are all filed in
    /// sidebar folders has no folder of its own; then only the notes and links change.
    /// Returns files it could not update (a note changed by hand meanwhile, an unreadable file); the rename itself still happened.
    @discardableResult
    public func renameSeriesFolder(from: String, to: String) throws -> [URL] {
        let skipped = try Self.withWriteLock { try renameSeriesFolderLocked(from: from, to: to) }
        return skipped + rewriteLinks(from: Self.folderName(from), to: Self.folderName(to))
    }

    /// The caller holds the write lock. Links are rewritten by the caller, after the lock.
    private func renameSeriesFolderLocked(from: String, to: String) throws -> [URL] {
        let fm = FileManager.default
        let oldName = Self.folderName(from), newName = Self.folderName(to)
        let source = notesRoot.appendingPathComponent(oldName, isDirectory: true)
        let destination = notesRoot.appendingPathComponent(newName, isDirectory: true)
        guard !oldName.isEmpty else { throw NoteIndexError.seriesFolderMissing(from) }
        guard !newName.isEmpty else { throw NoteIndexError.seriesFolderMissing(to) }
        // A sidebar folder is never a series folder, so it never moves with a series.
        let hasFolder = fm.fileExists(atPath: source.path) && !MeetingFolders.hasMarker(source)
        guard hasFolder || !members(ofSeriesFolder: oldName).isEmpty else { throw NoteIndexError.seriesFolderMissing(from) }

        if !Self.samePath(source, destination) {
            if fm.fileExists(atPath: destination.path) { throw NoteIndexError.seriesFolderExists(to) }
            if hasFolder { try fm.moveItem(at: source, to: destination) }
        } else if hasFolder, source.lastPathComponent != destination.lastPathComponent {
            // Case-only rename on a case-insensitive disk: go through a temporary name.
            let temp = notesRoot.appendingPathComponent(".lyra-rename-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: source, to: temp)
            try fm.moveItem(at: temp, to: destination)
        }

        // Read again after the folder moved, so each note is saved at the path it now has.
        var skipped: [URL] = []
        for loaded in members(ofSeriesFolder: oldName) {
            var edited = loaded.document
            edited.front.series = to
            do { _ = try saveLocked(edited, over: loaded) } catch { skipped.append(loaded.url) }
        }

        let oldPage = destination.appendingPathComponent(oldName + ".md")
        let newPage = destination.appendingPathComponent(newName + ".md")
        if hasFolder, oldName != newName, fm.fileExists(atPath: oldPage.path), !fm.fileExists(atPath: newPage.path) {
            try fm.moveItem(at: oldPage, to: newPage)
        }
        return skipped
    }

    /// Every Lyra note under `notesRoot` whose `series:` names the series with this folder name, wherever it is filed.
    private func members(ofSeriesFolder name: String) -> [LoadedNote] {
        markdownFiles(under: notesRoot).compactMap { url in
            guard Self.frontmatterID(of: url) != nil, let loaded = try? read(url),
                  let series = loaded.document.front.series, Self.folderName(series) == name else { return nil }
            return loaded
        }
    }

    // MARK: Links

    /// Rewrites `[[old]]`, `[[old|…]]` and `[[old#…]]` in every visible `.md` under the vault. Returns files it could not rewrite.
    /// The scan takes no lock (it can take a while on a big vault); each file found is read again and rewritten
    /// under the write lock, so a Lyra save to that file can't land between the read and the write. Never call it
    /// holding the lock.
    private func rewriteLinks(from oldName: String, to newName: String) -> [URL] {
        guard oldName != newName else { return [] }
        let needle = Data("[[\(oldName)".utf8)
        var skipped: [URL] = []
        for url in markdownFiles(under: vaultRoot) {
            linkScanProbe?(url)
            do {
                guard try Data(contentsOf: url).range(of: needle) != nil else { continue }
                try Self.withWriteLock { try rewriteLinksLocked(in: url, from: oldName, to: newName) }
            } catch {
                skipped.append(url)
            }
        }
        return skipped.sorted { $0.path < $1.path }
    }

    /// The caller holds the write lock.
    private func rewriteLinksLocked(in url: URL, from oldName: String, to newName: String) throws {
        let patterns = ["]]", "|", "#"].map { ("[[\(oldName)\($0)", "[[\(newName)\($0)") }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        let updated = patterns.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        guard updated != text else { return }
        try Self.writeAtomically(Data(updated.utf8), to: url)
    }

    // MARK: Files

    private func read(_ url: URL) throws -> LoadedNote {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw NoteDocumentError.missingFrontmatter }
        return LoadedNote(url: url, document: try NoteDocument.parse(text), fingerprint: Self.fingerprint(of: data))
    }

    /// Every `.md` file under `root`, skipping hidden files and folders (so `.obsidian/` and temp files).
    private func markdownFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "md" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// The `lyra_id` in the note's frontmatter, reading only the top of the file.
    private static func frontmatterID(of url: URL) -> UUID? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: scanByteLimit) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(scanLineLimit) where line.hasPrefix("lyra_id:") {
            return UUID(uuidString: line.dropFirst("lyra_id:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Temp file in the same folder, then swapped in, so a reader never sees half a note. Replacing never creates:
    /// a file that is gone (moved or trashed meanwhile) throws `fileNoSuchFile` instead of coming back at its old
    /// path. `mayCreate` writes a new file when there is none.
    static func writeAtomically(_ data: Data, to url: URL, mayCreate: Bool = false) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).lyra-tmp")
        do {
            try data.write(to: temp)
            copyKeptAttributes(from: url, to: temp)
            try swapIn(temp, at: url, mayCreate: mayCreate)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// The swap leaves the temp file's inode at the note's path, so give it the note's created date and permissions first
    /// (Obsidian sorts by created date). Best effort: a failure here never costs the write.
    private static func copyKeptAttributes(from url: URL, to temp: URL) {
        let manager = FileManager.default
        guard let existing = try? manager.attributesOfItem(atPath: url.path) else { return }
        let kept = existing.filter { $0.key == .creationDate || $0.key == .posixPermissions }
        try? manager.setAttributes(kept, ofItemAtPath: temp.path)
    }

    /// One atomic swap that fails if `url` is missing; afterwards `temp` holds the old contents and is removed.
    private static func swapIn(_ temp: URL, at url: URL, mayCreate: Bool) throws {
        if renamex_np(temp.path, url.path, UInt32(RENAME_SWAP)) == 0 {
            try? FileManager.default.removeItem(at: temp)
            return
        }
        switch errno {
        case ENOENT where mayCreate:
            // RENAME_EXCL: a file that appeared meanwhile is never replaced unseen.
            guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError(errno, url) }
        case ENOENT:
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        case ENOTSUP, EINVAL:
            // A disk without swap support: check, then replace (the write lock covers Lyra's own moves).
            guard mayCreate || FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        case let code:
            throw posixError(code, url)
        }
    }

    private static func posixError(_ code: Int32, _ url: URL) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                                                 NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }

    // MARK: Names

    private static func noteBaseName(title: String, date: Date) -> String {
        let name = MeetingPaths.sanitise(title).isEmpty ? "Meeting" : title
        return MeetingPaths(recordingsRoot: URL(fileURLWithPath: "/"), notesDir: URL(fileURLWithPath: "/"))
            .folderName(title: name, startedAt: date, timeZone: .current)
    }

    private static func folderName(_ series: String) -> String { MeetingPaths.sanitise(series) }

    static func seriesFolder(_ series: String?, under root: URL) -> URL {
        guard let series, !folderName(series).isEmpty else { return root }
        return root.appendingPathComponent(folderName(series), isDirectory: true)
    }

    /// Case-insensitive, because the vault lives on a case-insensitive disk.
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }
}
