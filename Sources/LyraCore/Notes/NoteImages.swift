import Foundation

/// Picture files that live beside a note: saved when Aidan pastes or drops one, found again for display, and moved
/// along when Lyra moves the note. Nothing here ever overwrites or deletes a file.
public enum NoteImages {
    /// Types saved with their own bytes; anything else is turned into PNG by the app first, so Obsidian can show it.
    public static let keptExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    private static let maxNameAttempts = 1000

    public static func keepsOwnBytes(ext: String) -> Bool { keptExtensions.contains(ext.lowercased()) }

    /// Saves `data` beside `note` as `Pasted image yyyyMMddHHmmss.ext` (Obsidian's own naming), adding ` 1`, ` 2`… when
    /// the name is taken. Returns the file name.
    public static func save(_ data: Data, ext: String, besideNote note: URL, now: Date = Date()) throws -> String {
        let folder = note.deletingLastPathComponent()
        let stamp = stampFormatter.string(from: now)
        let ext = ext.lowercased()
        let fm = FileManager.default
        // Written whole to a hidden file first, then moved into place: a move never replaces an existing file, so a
        // name taken in between just tries the next one.
        let temp = folder.appendingPathComponent(".lyra-picture-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        defer { try? fm.removeItem(at: temp) }  // only Lyra's own temporary file, left over if every name was taken
        for n in 0..<maxNameAttempts {
            let name = "Pasted image \(stamp)" + (n == 0 ? "" : " \(n)") + ".\(ext)"
            let url = folder.appendingPathComponent(name)
            guard !fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.moveItem(at: temp, to: url)
                return name
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Where `target` (from a picture line) is: beside the note, then the path from the note's folder, then from the
    /// vault root, then any visible file of that name in the vault, as Obsidian finds it.
    public static func resolve(_ target: String, note: URL, vaultRoot: URL) -> URL? {
        let fm = FileManager.default
        let folder = note.deletingLastPathComponent()
        let name = (target as NSString).lastPathComponent
        let candidates = [folder.appendingPathComponent(name), folder.appendingPathComponent(target),
                          vaultRoot.appendingPathComponent(target)]
        if let found = candidates.first(where: { isFile($0, fm) }) { return found }
        return findByName(name, under: vaultRoot)
    }

    /// The pictures `note` embeds by bare file name (`![[name.png]]`) that sit beside it: what moves with the note.
    static func embeddedBeside(_ document: NoteDocument, note: URL) -> [String] {
        let folder = note.deletingLastPathComponent()
        let lines = (document.myNotes + "\n" + document.expanded).components(separatedBy: "\n")
        var seen = Set<String>()
        return lines.compactMap { line -> String? in
            guard let target = NoteMarkdown.imageTarget(of: line), !target.contains("/"), seen.insert(target).inserted,
                  isFile(folder.appendingPathComponent(target), .default) else { return nil }
            return target
        }
    }

    /// Moves the pictures `document` embeds from beside `old` to beside `new`, skipping any name already taken there.
    /// Best effort: a picture that can't move stays where it was, and Obsidian still finds it by name.
    static func moveEmbedded(_ document: NoteDocument, from old: URL, to new: URL) {
        let from = old.deletingLastPathComponent(), to = new.deletingLastPathComponent()
        guard from.standardizedFileURL.path != to.standardizedFileURL.path else { return }
        for name in embeddedBeside(document, note: old) {
            let target = to.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.moveItem(at: from.appendingPathComponent(name), to: target)
        }
    }

    // MARK: Helpers

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    private static func isFile(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func findByName(_ name: String, under root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return url }
        }
        return nil
    }
}
