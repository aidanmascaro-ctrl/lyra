import Foundation

/// Brings notes written in an older layout (headings at the section's own level, Claude's topic headings as the
/// small heading, a plain transcript, no jump line) to the current one, once, keeping every word: a note that
/// already renders as it is on disk is not touched.
/// Runs at launch; a note that changes under it is left for the next launch.
public enum NoteLayoutUpgrade {
    /// Plain-English problems, one per note that couldn't be rewritten; empty when all is well.
    public static func run(index: NoteIndex) -> [String] {
        var problems: [String] = []
        for loaded in index.allNotes() {
            do {
                let onDisk = try String(contentsOf: loaded.url, encoding: .utf8)
                let current = currentLayout(of: loaded.document)
                guard current.render() != onDisk else { continue }
                _ = try index.save(current, over: loaded)
            } catch where NoteIndex.isChangedOrMoved(error) {
                continue  // being edited or moved right now: next launch
            } catch {
                problems.append("Lyra couldn't update the layout of “\(loaded.url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        return problems
    }

    /// The document with each edited section written as the editor writes it now (headings at their nested level).
    /// Claude's grey headings were the small heading before 2026-10-27 and are the big (topic) heading since.
    static func currentLayout(of document: NoteDocument) -> NoteDocument {
        var current = document
        current.myNotes = NoteFormatting.text(for: NoteMarkdown.parse(document.myNotes), keepingStyleOf: document.myNotes)
        let expanded = NoteMarkdown.parse(document.expanded).map { block -> NoteBlock in
            guard block.byClaude, block.kind == .heading2 else { return block }
            var topic = block
            topic.kind = .heading1
            return topic
        }
        current.expanded = NoteFormatting.text(for: expanded, keepingStyleOf: document.expanded)
        return current
    }
}
