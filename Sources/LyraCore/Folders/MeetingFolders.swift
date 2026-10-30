import Foundation

/// Aidan's sidebar folders: real directories directly under `Meetings/`, told apart from series folders by a hidden
/// marker file holding the folder's colour (Obsidian doesn't show it). One level only. Every directory change holds
/// NoteIndex's write lock, so it never interleaves with a note save or move.
public struct MeetingFolders: Sendable {
    public static let markerName = ".lyra-folder.json"

    public let index: NoteIndex
    private var notesRoot: URL { index.notesRoot }

    public init(index: NoteIndex) {
        self.index = index
    }

    private struct Marker: Codable {
        var colour: FolderColour
    }

    // MARK: Read

    /// Every sidebar folder, by name. A marker Lyra can't read counts as grey.
    public func all() -> [SidebarFolder] {
        subdirectories()
            .filter(Self.hasMarker)
            .map { SidebarFolder(name: $0.lastPathComponent, colour: colour(of: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A directory directly under `Meetings/` holding the marker.
    public func isFolder(_ url: URL) -> Bool {
        Self.isDirectChild(url, of: notesRoot) && Self.hasMarker(url)
    }

    /// The sidebar folder the file sits directly in, or nil.
    public func folder(of note: URL) -> String? {
        Self.folderName(of: note, under: notesRoot)
    }

    /// Where the sidebar folder called `name` lives (whether or not it exists).
    public func url(of name: String) -> URL {
        notesRoot.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Change

    /// Makes `Meetings/<name>/` and its marker; the colour is the next one in the palette.
    public func create(_ name: String) throws -> SidebarFolder {
        let name = try validName(name)
        return try NoteIndex.withWriteLock {
            guard taken(name, except: nil) == nil else { throw MeetingFoldersError.nameTaken(name) }
            let palette = FolderColour.allCases
            let folder = SidebarFolder(name: name, colour: palette[subdirectories().filter(Self.hasMarker).count % palette.count])
            // Not intermediate, so it fails rather than adopting a folder that appeared meanwhile.
            try FileManager.default.createDirectory(at: url(of: name), withIntermediateDirectories: false)
            try writeMarker(folder.colour, in: url(of: name), mayCreate: true)
            return folder
        }
    }

    /// Renames the directory; the marker and notes move with it, so no note names or links change.
    public func rename(_ name: String, to newName: String) throws {
        let newName = try validName(newName)
        try NoteIndex.withWriteLock {
            let source = url(of: name)
            guard isFolder(source) else { throw MeetingFoldersError.missingFolder(name) }
            guard taken(newName, except: source) == nil else { throw MeetingFoldersError.nameTaken(newName) }
            try moveDirectory(source, to: url(of: newName))
        }
    }

    public func setColour(_ colour: FolderColour, of name: String) throws {
        try NoteIndex.withWriteLock {
            let folder = url(of: name)
            guard isFolder(folder) else { throw MeetingFoldersError.missingFolder(name) }
            try writeMarker(colour, in: folder, mayCreate: false)
        }
    }

    // MARK: Shared with series code

    static func hasMarker(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerName).path)
    }

    /// The sidebar folder a note sits directly in, given only the notes root.
    static func folderName(of note: URL, under root: URL) -> String? {
        let parent = note.deletingLastPathComponent()
        guard isDirectChild(parent, of: root), hasMarker(parent) else { return nil }
        return parent.resolvingSymlinksInPath().lastPathComponent
    }

    // MARK: Helpers

    /// Trimmed, not empty, and already safe as a file name and inside `[[links]]` (series-name rules).
    private func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MeetingFoldersError.emptyName }
        guard !name.hasPrefix("."), MeetingPaths.sanitise(name) == name else { throw MeetingFoldersError.invalidName(name) }
        return name
    }

    /// An existing directory of either kind with this name (case-insensitive), other than `except`.
    private func taken(_ name: String, except: URL?) -> URL? {
        subdirectories().first { dir in
            dir.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame && !(except.map { NoteIndex.samePath($0, dir) } ?? false)
        }
    }

    private func subdirectories() -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: notesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return found.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func colour(of folder: URL) -> FolderColour {
        let markerURL = folder.appendingPathComponent(Self.markerName)
        guard let data = try? Data(contentsOf: markerURL), let marker = try? JSONDecoder().decode(Marker.self, from: data) else {
            return .grey
        }
        return marker.colour
    }

    private func writeMarker(_ colour: FolderColour, in folder: URL, mayCreate: Bool) throws {
        let data = try JSONEncoder().encode(Marker(colour: colour))
        try NoteIndex.writeAtomically(data, to: folder.appendingPathComponent(Self.markerName), mayCreate: mayCreate)
    }

    /// The caller holds the write lock. A case-only rename goes through a temporary name (case-insensitive disk).
    private func moveDirectory(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard source.lastPathComponent != destination.lastPathComponent else { return }
        guard NoteIndex.samePath(source, destination) else { return try fm.moveItem(at: source, to: destination) }
        let temp = notesRoot.appendingPathComponent(".lyra-rename-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: source, to: temp)
        try fm.moveItem(at: temp, to: destination)
    }

    private static func isDirectChild(_ url: URL, of root: URL) -> Bool {
        url.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path
    }
}
