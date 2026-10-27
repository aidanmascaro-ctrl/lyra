import Foundation

/// Keeps a note's two editors and its file in step, never writing over text the other side hasn't seen.
///
/// Each section is tracked on its own: what its editor shows (`shown`: what it sent out, or a push it accepted),
/// the push it hasn't answered yet, and its conflict. Any newer version of the file (watcher, a merge during a
/// save, a rename, Lyra's own write) goes through `accept`, which pushes every section whose text differs from
/// what its editor shows. Each push has an id; the editor answers it with `ack` (took it, or refused because it
/// had unsent typing). A refusal, or the editor sending text while a push is still unanswered, is a conflict for
/// that section, and nothing is written to a section in conflict until Aidan picks Reload or Keep mine.
public struct NoteSync: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Show these blocks unless the editor has unsent typing; answer with `ack(section, id:, accepted:)`.
        case push(NoteSection, [NoteBlock], id: Int)
        /// Show these blocks, dropping any unsent typing (Aidan chose Reload).
        case forcePush(NoteSection, [NoteBlock])
    }

    public struct Conflict: Sendable {
        /// The editor's text, kept up to date while Aidan decides.
        public internal(set) var mine: [NoteBlock]
        /// The file as it is now.
        public internal(set) var disk: LoadedNote
    }

    public private(set) var loaded: LoadedNote
    public private(set) var conflicts: [NoteSection: Conflict] = [:]
    private var shown: [NoteSection: String] = [:]
    private var pending: [NoteSection: (id: Int, text: String)] = [:]
    private var nextID = 1

    public init(loaded: LoadedNote) {
        self.loaded = loaded
        for section in NoteSection.allCases { shown[section] = Self.canonical(section.text(in: loaded.document)) }
    }

    /// The watcher saw the file change. Lyra's own last write (same fingerprint, same place) changes nothing; the
    /// same text somewhere else (moved in Obsidian) is followed there, with nothing to push.
    public mutating func diskChanged(_ disk: LoadedNote) -> [Effect] {
        guard disk.fingerprint != loaded.fingerprint || disk.url.standardizedFileURL != loaded.url.standardizedFileURL
        else { return [] }
        return accept(disk)
    }

    /// A newer version of the file, wherever it came from. `saved` is the section the editor just wrote.
    public mutating func accept(_ note: LoadedNote, saved: NoteSection? = nil) -> [Effect] {
        loaded = note
        for section in conflicts.keys { conflicts[section]?.disk = note }
        var effects: [Effect] = []
        for section in NoteSection.allCases where section != saved && conflicts[section] == nil {
            let text = Self.canonical(section.text(in: note.document))
            guard text != (pending[section]?.text ?? shown[section]) else { continue }
            pending[section] = (nextID, text)
            effects.append(.push(section, NoteMarkdown.parse(text), id: nextID))
            nextID += 1
        }
        return effects
    }

    /// The editor's answer to push `id`. An answer to an older push than the one pending is ignored.
    public mutating func ack(_ section: NoteSection, id: Int, accepted: Bool) {
        guard let push = pending[section], push.id == id else { return }
        pending[section] = nil
        if accepted { shown[section] = push.text } else { openConflict(section, mine: NoteMarkdown.parse(shown[section] ?? "")) }
    }

    /// The editor sent out its blocks: saved, unless the section is in conflict, a push to it is still unanswered
    /// (the editor never showed what the file now holds), or the save finds a change made meanwhile.
    public mutating func edited(_ blocks: [NoteBlock], in section: NoteSection, index: NoteIndex) throws -> [Effect] {
        let text = Self.canonical(NoteMarkdown.render(blocks))
        if conflicts[section] != nil {
            conflicts[section]?.mine = blocks
            return []
        }
        if let push = pending.removeValue(forKey: section) {
            // Sent before the push was answered: unless it is that very text, it was typed over an older version.
            guard push.text == text else {
                openConflict(section, mine: blocks)
                return []
            }
            shown[section] = text
            return []
        }
        shown[section] = text
        switch try NoteEdits.save(blocks, to: section, over: loaded, index: index) {
        case .saved(let note):
            return accept(note, saved: section)
        case .conflict(let disk):
            openConflict(section, mine: blocks)
            return accept(disk, saved: section)
        }
    }

    /// Lyra writing Expanded (Claude's additions): saved only while the section is settled, then pushed to its
    /// editor like any outside change, so typing in flight still wins and is asked about. Lyra never writes My
    /// notes, so there is no way to name it here.
    public mutating func writeExpanded(_ blocks: [NoteBlock], index: NoteIndex) throws -> (effects: [Effect], written: Bool) {
        guard conflicts[.expanded] == nil, pending[.expanded] == nil else { return ([], false) }
        switch try NoteEdits.save(blocks, to: .expanded, over: loaded, index: index) {
        case .saved(let note): return (accept(note), true)
        case .conflict(let disk): return (accept(disk), false)
        }
    }

    /// "Reload": the file's text wins, unsent typing included.
    public mutating func reload(_ section: NoteSection) -> [Effect] {
        guard conflicts.removeValue(forKey: section) != nil else { return [] }
        let text = Self.canonical(section.text(in: loaded.document))
        shown[section] = text
        pending[section] = nil
        return [.forcePush(section, NoteMarkdown.parse(text))]
    }

    /// "Keep mine": the editor's text is written over the section as the file is right now.
    public mutating func keepMine(_ section: NoteSection, index: NoteIndex) throws -> [Effect] {
        guard let conflict = conflicts[section] else { return [] }
        let fresh = try index.load(conflict.disk.document.front.lyraID, hint: conflict.disk.url)
        let note = try NoteEdits.keepMine(conflict.mine, section: section, over: fresh, index: index)
        conflicts[section] = nil
        pending[section] = nil
        shown[section] = Self.canonical(NoteMarkdown.render(conflict.mine))
        return accept(note, saved: section)
    }

    private mutating func openConflict(_ section: NoteSection, mine: [NoteBlock]) {
        pending[section] = nil
        if conflicts[section] == nil { conflicts[section] = Conflict(mine: mine, disk: loaded) }
    }

    /// Text as the editor would write it back, so formatting differences alone never count as a change.
    private static func canonical(_ text: String) -> String { NoteMarkdown.render(NoteMarkdown.parse(text)) }
}
