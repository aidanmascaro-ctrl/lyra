import Foundation

/// The two sections Aidan edits in the meeting window. Transcript has its own rename path.
public enum NoteSection: Sendable {
    case myNotes, expanded

    public func text(in document: NoteDocument) -> String {
        switch self {
        case .myNotes: document.myNotes
        case .expanded: document.expanded
        }
    }

    func set(_ text: String, in document: inout NoteDocument) {
        switch self {
        case .myNotes: document.myNotes = text
        case .expanded: document.expanded = text
        }
    }
}

public enum SectionSave: Sendable {
    case saved(LoadedNote)
    /// The same section was changed elsewhere since it was loaded; nothing was written.
    case conflict(disk: LoadedNote)
}

/// Saves one section of a note from the editor without ever writing over an edit made elsewhere to that section.
public enum NoteEdits {
    /// Writes `blocks` as `section`. If the file changed meanwhile only in other places (Claude streaming into
    /// Expanded while Aidan types in My notes), the section is put into the file as it is now; if this section
    /// itself changed, nothing is written and the file as it is now comes back for Aidan to choose.
    public static func save(_ blocks: [NoteBlock], to section: NoteSection, over loaded: LoadedNote,
                            index: NoteIndex) throws -> SectionSave {
        let text = NoteMarkdown.render(blocks)
        var document = loaded.document
        section.set(text, in: &document)
        if document == loaded.document { return .saved(loaded) }
        do {
            return .saved(try index.save(document, over: loaded))
        } catch let error where isChangedOrMoved(error) {
            // Found again by `lyra_id`: Lyra may have renamed it after the meeting, or Aidan moved it in Obsidian.
            let disk = try index.load(loaded.document.front.lyraID, hint: loaded.url)
            guard section.text(in: disk.document) == section.text(in: loaded.document) else { return .conflict(disk: disk) }
            return .saved(try keepMine(blocks, section: section, over: disk, index: index))
        }
    }

    private static func isChangedOrMoved(_ error: Error) -> Bool {
        if case NoteIndexError.changedOnDisk = error { return true }
        return (error as? CocoaError)?.code == .fileReadNoSuchFile
    }

    /// "Keep mine": this section becomes `blocks`, everything else stays as it is on disk now.
    public static func keepMine(_ blocks: [NoteBlock], section: NoteSection, over disk: LoadedNote, index: NoteIndex) throws -> LoadedNote {
        let text = NoteMarkdown.render(blocks)
        return try index.update(disk) { section.set(text, in: &$0) }
    }

    /// Records Claude's blocks as Lyra's own writing, so Re-expand knows they're untouched grey.
    public static func rememberGrey(_ blocks: [NoteBlock], meetingFolder: URL) throws {
        let new = ExpandedMerge.hashes(of: blocks)
        guard !new.isEmpty else { return }
        try AfterMeeting.updateMeeting(in: meetingFolder) { meeting in
            let known = meeting.expandedHashes ?? []
            meeting.expandedHashes = known + new.filter { !known.contains($0) }
        }
    }
}
