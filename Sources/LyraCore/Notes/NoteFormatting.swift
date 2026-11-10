import Foundation

/// Writes blocks back over a section's existing Markdown keeping Aidan's own style: every line whose content is
/// unchanged keeps its exact text (list numbers like `1. 1. 1.`, odd indents), and only lines that changed, or
/// headings in an old marker style, are written the way `NoteMarkdown.render` writes them.
public enum NoteFormatting {
    public static func text(for blocks: [NoteBlock], keepingStyleOf original: String) -> String {
        guard !original.isEmpty else { return NoteMarkdown.render(blocks) }
        let originalLines = original.components(separatedBy: "\n")
        let kept = keptLines(for: blocks, originalBlocks: NoteMarkdown.parse(original), originalLines: originalLines)
        let fresh = NoteMarkdown.renderLines(blocks)
        var out: [String] = []
        for i in blocks.indices {
            if i > 0, needsGap(between: blocks[i - 1], and: blocks[i]) { out.append("") }
            out.append(kept[i] ?? fresh[i])
        }
        return out.joined(separator: "\n")
    }

    /// For each new block, the original line it came from unchanged (matched in order), if any.
    private static func keptLines(for blocks: [NoteBlock], originalBlocks: [NoteBlock], originalLines: [String]) -> [String?] {
        let diff = blocks.difference(from: originalBlocks)
        let removed = Set(diff.removals.map(offset))
        let inserted = Set(diff.insertions.map(offset))
        let unchangedOld = originalBlocks.indices.filter { !removed.contains($0) }
        let unchangedNew = blocks.indices.filter { !inserted.contains($0) }
        var kept = [String?](repeating: nil, count: blocks.count)
        for (old, new) in zip(unchangedOld, unchangedNew) where !isHeading(blocks[new]) {
            kept[new] = originalLines[old]
        }
        return kept
    }

    private static func offset(_ change: CollectionDifference<NoteBlock>.Change) -> Int {
        switch change {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }

    private static func isHeading(_ block: NoteBlock) -> Bool { block.kind == .heading1 || block.kind == .heading2 }

    /// Whatever blank line `NoteMarkdown.render` puts between these two blocks.
    private static func needsGap(between previous: NoteBlock, and block: NoteBlock) -> Bool {
        NoteMarkdown.render([previous, block]).components(separatedBy: "\n").count > 2
    }
}
