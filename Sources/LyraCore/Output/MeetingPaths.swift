import Foundation

/// Names and reserves a meeting's recordings folder and Obsidian note without ever overwriting.
/// Files inside a folder: meeting.json, transcript.json, meeting.caf, mic.caf (later .m4a).
public struct MeetingPaths: @unchecked Sendable {
    public static var defaultRecordingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Lyra Recordings")
    }
    public static var defaultNotesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Obsidian Vault/Aidan Business/Meetings")
    }

    public let recordingsRoot: URL
    public let notesDir: URL
    private let fileManager: FileManager

    public init(recordingsRoot: URL, notesDir: URL, fileManager: FileManager = .default) {
        self.recordingsRoot = recordingsRoot
        self.notesDir = notesDir
        self.fileManager = fileManager
    }

    public func folderName(title: String, startedAt: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HHmm"
        let prefix = "\(f.string(from: startedAt)) — "
        // Whole name <= 120 Characters and <= 200 bytes (255 max, room for " (nn)" and ".md").
        return prefix + Self.sanitise(title, limit: 120 - prefix.count, byteLimit: 200 - prefix.utf8.count)
    }

    public func reserve(for meeting: Meeting, timeZone: TimeZone) throws -> (folder: URL, note: URL) {
        var title = meeting.title
        if Self.sanitise(title).isEmpty { title = meeting.appName }
        let base = folderName(title: title, startedAt: meeting.startedAt, timeZone: timeZone)
        try fileManager.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: notesDir, withIntermediateDirectories: true)
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) (\(n))"
            let folder = recordingsRoot.appendingPathComponent(name)
            let note = notesDir.appendingPathComponent(name + ".md")
            if !fileManager.fileExists(atPath: folder.path), !fileManager.fileExists(atPath: note.path) {
                // Non-intermediate create is atomic: fails if another reserver took the name.
                do {
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                    return (folder, note)
                } catch CocoaError.fileWriteFileExists {}
            }
            n += 1
        }
    }

    /// Replace forbidden and control scalars with "-", drop the ones that break Obsidian links (`# [ ] ^ |`),
    /// collapse spaces, trim, then cap at `limit` Characters and `byteLimit` UTF-8 bytes (cut on a Character boundary).
    static func sanitise(_ title: String, limit: Int = 120, byteLimit: Int = 200) -> String {
        let bad = Set("/:\\?*\"<>".unicodeScalars)
        let breaksLinks = Set("#[]^|".unicodeScalars)
        var scalars = String.UnicodeScalarView()
        for u in title.unicodeScalars where !breaksLinks.contains(u) {
            scalars.append(bad.contains(u) || u.properties.generalCategory == .control ? "-" : u)
        }
        var s = String(scalars)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        var out = ""
        var bytes = 0
        for ch in s.prefix(limit) {
            let b = String(ch).utf8.count
            if bytes + b > byteLimit { break }
            out.append(ch); bytes += b
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
