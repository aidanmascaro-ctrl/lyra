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

    public var errorDescription: String? {
        switch self {
        case .notFound: "Lyra couldn't find this meeting's note in the Meetings folder."
        case .changedOnDisk: "This note was changed in Obsidian since Lyra opened it, so Lyra didn't save over it."
        case .seriesFolderMissing(let name): "Lyra couldn't find a series folder called “\(name)”."
        case .seriesFolderExists(let name): "There is already a series folder called “\(name)”, so Lyra didn't rename into it."
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
public struct NoteIndex: Sendable {
    public let notesRoot: URL
    public let vaultRoot: URL

    /// Frontmatter sits at the top of a note; only this many lines are read when scanning.
    private static let scanLineLimit = 40
    private static let scanByteLimit = 16 * 1024

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
        let current = try Data(contentsOf: loaded.url)
        guard Self.fingerprint(of: current) == loaded.fingerprint else { throw NoteIndexError.changedOnDisk(loaded.url) }
        let data = Data(document.render().utf8)
        try Self.writeAtomically(data, to: loaded.url)
        return LoadedNote(url: loaded.url, document: document, fingerprint: Self.fingerprint(of: data))
    }

    // MARK: Rename and move

    /// Moves the note to `notesRoot/<series>/<date — title>.md` and points `[[links]]` at the new name.
    public func relocate(_ loaded: LoadedNote, title: String, series: String?) throws -> LoadedNote {
        try relocateReportingSkips(loaded, title: title, series: series).note
    }

    public func relocateReportingSkips(_ loaded: LoadedNote, title: String, series: String?) throws -> Relocation {
        let fm = FileManager.default
        let folder = Self.seriesFolder(series, under: notesRoot)
        let base = Self.noteBaseName(title: title, date: loaded.document.front.date)

        var target = folder.appendingPathComponent(base + ".md")
        if Self.samePath(target, loaded.url) { return Relocation(note: loaded, skippedLinkFiles: []) }
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) (\(n)).md")
            if Self.samePath(target, loaded.url) { return Relocation(note: loaded, skippedLinkFiles: []) }
            n += 1
        }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.moveItem(at: loaded.url, to: target)

        let oldName = loaded.url.deletingPathExtension().lastPathComponent
        let newName = target.deletingPathExtension().lastPathComponent
        let skipped = rewriteLinks(from: oldName, to: newName)
        return Relocation(note: try read(target), skippedLinkFiles: skipped)
    }

    /// Renames the folder, updates `series:` in the notes inside, and renames the series page and its links.
    /// Returns files it could not update (a note changed by hand meanwhile, an unreadable file); the rename itself still happened.
    @discardableResult
    public func renameSeriesFolder(from: String, to: String) throws -> [URL] {
        let fm = FileManager.default
        let oldName = Self.folderName(from), newName = Self.folderName(to)
        let source = notesRoot.appendingPathComponent(oldName, isDirectory: true)
        let destination = notesRoot.appendingPathComponent(newName, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { throw NoteIndexError.seriesFolderMissing(from) }
        guard !newName.isEmpty else { throw NoteIndexError.seriesFolderMissing(to) }

        if !Self.samePath(source, destination) {
            if fm.fileExists(atPath: destination.path) { throw NoteIndexError.seriesFolderExists(to) }
            try fm.moveItem(at: source, to: destination)
        } else if source.lastPathComponent != destination.lastPathComponent {
            // Case-only rename on a case-insensitive disk: go through a temporary name.
            let temp = notesRoot.appendingPathComponent(".lyra-rename-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: source, to: temp)
            try fm.moveItem(at: temp, to: destination)
        }

        var skipped: [URL] = []
        for url in markdownFiles(under: destination) {
            guard Self.frontmatterID(of: url) != nil, let loaded = try? read(url),
                  let series = loaded.document.front.series, Self.folderName(series) == oldName else { continue }
            var edited = loaded.document
            edited.front.series = to
            do { _ = try save(edited, over: loaded) } catch { skipped.append(url) }
        }

        let oldPage = destination.appendingPathComponent(oldName + ".md")
        let newPage = destination.appendingPathComponent(newName + ".md")
        if oldName != newName, fm.fileExists(atPath: oldPage.path), !fm.fileExists(atPath: newPage.path) {
            try fm.moveItem(at: oldPage, to: newPage)
        }
        if oldName != newName { skipped += rewriteLinks(from: oldName, to: newName) }
        return skipped
    }

    // MARK: Links

    /// Rewrites `[[old]]`, `[[old|…]]` and `[[old#…]]` in every visible `.md` under the vault. Returns files it could not rewrite.
    private func rewriteLinks(from oldName: String, to newName: String) -> [URL] {
        guard oldName != newName else { return [] }
        let patterns = ["]]", "|", "#"].map { ("[[\(oldName)\($0)", "[[\(newName)\($0)") }
        var skipped: [URL] = []
        for url in markdownFiles(under: vaultRoot) {
            do {
                let data = try Data(contentsOf: url)
                guard data.range(of: Data("[[\(oldName)".utf8)) != nil else { continue }
                guard let text = String(data: data, encoding: .utf8) else { skipped.append(url); continue }
                let updated = patterns.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
                guard updated != text else { continue }
                try Self.writeAtomically(Data(updated.utf8), to: url)
            } catch {
                skipped.append(url)
            }
        }
        return skipped.sorted { $0.path < $1.path }
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

    /// Temp file in the same folder, then swapped in, so a reader never sees half a note.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).lyra-tmp")
        do {
            try data.write(to: temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: Names

    private static func noteBaseName(title: String, date: Date) -> String {
        let name = MeetingPaths.sanitise(title).isEmpty ? "Meeting" : title
        return MeetingPaths(recordingsRoot: URL(fileURLWithPath: "/"), notesDir: URL(fileURLWithPath: "/"))
            .folderName(title: name, startedAt: date, timeZone: .current)
    }

    private static func folderName(_ series: String) -> String { MeetingPaths.sanitise(series) }

    private static func seriesFolder(_ series: String?, under root: URL) -> URL {
        guard let series, !folderName(series).isEmpty else { return root }
        return root.appendingPathComponent(folderName(series), isDirectory: true)
    }

    /// Case-insensitive, because the vault lives on a case-insensitive disk.
    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }
}
