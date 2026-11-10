import Foundation

/// Typing that couldn't be saved because its section changed elsewhere meanwhile, kept when the meeting page closes
/// before Aidan picked Reload or Keep mine (the last save on leaving the page can be the one that conflicts).
/// Lives in the meeting's recordings folder, never in the vault; reopening the meeting asks again.
public enum UnsavedTyping {
    static let fileName = "unsaved-typing.json"

    /// Replaces what is kept for each section given; other sections keep theirs.
    public static func save(_ sections: [NoteSection: [NoteBlock]], in folder: URL) throws {
        guard !sections.isEmpty else { return }
        var kept = stored(in: folder)
        for (section, blocks) in sections { kept[key(section)] = blocks }
        try write(kept, in: folder)
    }

    public static func load(from folder: URL) -> [NoteSection: [NoteBlock]] {
        var result: [NoteSection: [NoteBlock]] = [:]
        for section in NoteSection.allCases {
            if let blocks = stored(in: folder)[key(section)] { result[section] = blocks }
        }
        return result
    }

    /// Aidan chose Reload or Keep mine: that section's kept typing is done with. The last one going moves the file
    /// to the Trash.
    public static func clear(_ section: NoteSection, in folder: URL) throws {
        var kept = stored(in: folder)
        guard kept.removeValue(forKey: key(section)) != nil else { return }
        if kept.isEmpty {
            try FileManager.default.trashItem(at: url(in: folder), resultingItemURL: nil)
        } else {
            try write(kept, in: folder)
        }
    }

    private static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    private static func key(_ section: NoteSection) -> String {
        switch section {
        case .myNotes: "myNotes"
        case .expanded: "expanded"
        }
    }

    private static func stored(in folder: URL) -> [String: [NoteBlock]] {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return [:] }
        return (try? JSONDecoder().decode([String: [NoteBlock]].self, from: data)) ?? [:]
    }

    private static func write(_ kept: [String: [NoteBlock]], in folder: URL) throws {
        try JSONEncoder().encode(kept).write(to: url(in: folder), options: .atomic)
    }
}
