import Foundation

/// Keeps a note's two editors and its file in step, never writing over text the other side hasn't seen.
///
/// `loaded` is the file as last known; `shown` is what each editor holds (what it sent out, or a push it
/// accepted). Any newer version of the file — from the watcher, a merge during a save, a rename — goes through
/// `accept`, which pushes every section whose text differs from what its editor shows. The editor answers each
/// push with `ack`: it took it, or it had unsent typing and refused, which is a conflict for that section.
/// While a section is in conflict nothing is saved to it until Aidan picks Reload or Keep mine.
public struct NoteSync: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Show these blocks unless the editor has unsent typing (it answers with `ack`).
        case push(NoteSection, [NoteBlock])
        /// Show these blocks, dropping any unsent typing (Aidan chose Reload).
        case forcePush(NoteSection, [NoteBlock])
    }

    public struct Conflict: Sendable {
        public let section: NoteSection
        /// The editor's text, kept up to date while Aidan decides.
        public internal(set) var mine: [NoteBlock]
        /// The file as it is now.
        public internal(set) var disk: LoadedNote
    }

    public private(set) var loaded: LoadedNote
    public private(set) var conflict: Conflict?
    private var shown: [NoteSection: String] = [:]
    /// Pushes not yet answered by their editor.
    private var pushed: [NoteSection: String] = [:]

    public init(loaded: LoadedNote) {
        self.loaded = loaded
        for section in NoteSection.allCases { shown[section] = Self.canonical(section.text(in: loaded.document)) }
    }

    /// The watcher saw the file change. Lyra's own last write (same fingerprint) changes nothing.
    public mutating func diskChanged(_ disk: LoadedNote) -> [Effect] {
        guard disk.fingerprint != loaded.fingerprint else { return [] }
        return accept(disk)
    }

    /// A newer version of the file, wherever it came from. `saved` is the section the editor just wrote.
    public mutating func accept(_ note: LoadedNote, saved: NoteSection? = nil) -> [Effect] {
        loaded = note
        conflict?.disk = note
        var effects: [Effect] = []
        for section in NoteSection.allCases where section != saved && section != conflict?.section {
            let text = Self.canonical(section.text(in: note.document))
            guard text != (pushed[section] ?? shown[section]) else { continue }
            pushed[section] = text
            effects.append(.push(section, NoteMarkdown.parse(text)))
        }
        return effects
    }

    /// The editor's answer to the last push for `section`.
    public mutating func ack(_ section: NoteSection, accepted: Bool) {
        guard let text = pushed.removeValue(forKey: section) else { return }
        if accepted {
            shown[section] = text
        } else if conflict == nil {
            conflict = Conflict(section: section, mine: NoteMarkdown.parse(shown[section] ?? ""), disk: loaded)
        }
    }

    /// The editor sent out its blocks: saved, unless the section is in conflict or the save finds one.
    public mutating func edited(_ blocks: [NoteBlock], in section: NoteSection, index: NoteIndex) throws -> [Effect] {
        if conflict?.section == section {
            conflict?.mine = blocks
            return []
        }
        // The editor's own text supersedes any push it hasn't answered.
        pushed[section] = nil
        shown[section] = Self.canonical(NoteMarkdown.render(blocks))
        switch try NoteEdits.save(blocks, to: section, over: loaded, index: index) {
        case .saved(let note):
            return accept(note, saved: section)
        case .conflict(let disk):
            if conflict == nil { conflict = Conflict(section: section, mine: blocks, disk: disk) }
            return accept(disk, saved: section)
        }
    }

    /// "Reload": the file's text wins, unsent typing included.
    public mutating func reload() -> [Effect] {
        guard let conflict else { return [] }
        self.conflict = nil
        let text = Self.canonical(conflict.section.text(in: conflict.disk.document))
        shown[conflict.section] = text
        pushed[conflict.section] = nil
        return [.forcePush(conflict.section, NoteMarkdown.parse(text))] + accept(conflict.disk, saved: conflict.section)
    }

    /// "Keep mine": the editor's text is written over the section as the file is right now.
    public mutating func keepMine(index: NoteIndex) throws -> [Effect] {
        guard let conflict else { return [] }
        let fresh = try index.load(conflict.disk.document.front.lyraID, hint: conflict.disk.url)
        let note = try NoteEdits.keepMine(conflict.mine, section: conflict.section, over: fresh, index: index)
        self.conflict = nil
        shown[conflict.section] = Self.canonical(NoteMarkdown.render(conflict.mine))
        return accept(note, saved: conflict.section)
    }

    /// Text as the editor would write it back, so formatting differences alone never count as a change.
    private static func canonical(_ text: String) -> String { NoteMarkdown.render(NoteMarkdown.parse(text)) }
}
