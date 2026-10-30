import Foundation
import LyraCore

/// What the sidebar reads: Aidan's folders and every meeting (each knowing the folder it is filed in).
struct SidebarSnapshot: Sendable {
    var folders: [SidebarFolder]
    var notes: [MeetingSummary]
}

/// The vault work behind the sidebar, as closures so tests can stand in for the disk. Every one runs off the main
/// actor and returns plain-English problems (empty when all went well) or throws.
struct SidebarStore: Sendable {
    var load: @Sendable () -> SidebarSnapshot
    var move: @Sendable (MeetingSummary, String?) throws -> [String]
    /// A new folder called "New folder" (or "New folder 2"…), ready to be named.
    var create: @Sendable () throws -> SidebarFolder
    var rename: @Sendable (String, String) throws -> Void
    var setColour: @Sendable (FolderColour, String) throws -> Void
    var remove: @Sendable (String) throws -> [String]
    var trash: @Sendable (MeetingSummary) -> [String]

    static let empty = SidebarStore(load: { SidebarSnapshot(folders: [], notes: []) }, move: { _, _ in [] },
                                    create: { SidebarFolder(name: "New folder", colour: .grey) }, rename: { _, _ in },
                                    setColour: { _, _ in }, remove: { _ in [] }, trash: { _ in [] })

    static func live(index: NoteIndex, recordingsRoot: URL) -> SidebarStore {
        let folders = MeetingFolders(index: index)
        return SidebarStore(
            load: { SidebarSnapshot(folders: folders.all(), notes: HomeModel.summaries(notes: index, recordingsRoot: recordingsRoot)) },
            move: { summary, folder in
                try FolderActions.move(try index.load(summary.id, hint: summary.note), to: folder, index: index).problems
            },
            create: { try createUntitled(in: folders) },
            rename: { try folders.rename($0, to: $1) },
            setColour: { try folders.setColour($0, of: $1) },
            remove: { try FolderActions.remove($0, index: index) },
            trash: { MeetingTrash.trash(id: $0.id, folder: $0.folder, index: index) })
    }

    private static let untitled = "New folder"
    private static let untitledTries = 100

    private static func createUntitled(in folders: MeetingFolders) throws -> SidebarFolder {
        for n in 1...untitledTries {
            do { return try folders.create(n == 1 ? untitled : "\(untitled) \(n)") } catch MeetingFoldersError.nameTaken {
                continue
            }
        }
        throw MeetingFoldersError.nameTaken(untitled)
    }
}
