import Foundation

/// Keeps Aidan's edits safe in an Expanded note: tells Claude's grey blocks from his white ones,
/// folds new My-notes points in on re-expand, and moves points (with what hangs off them) around.
public enum ExpandedMerge {
    /// Hashes of the grey blocks, recorded when Lyra writes them so a later edit can be spotted.
    public static func hashes(of blocks: [NoteBlock]) -> [String] {
        blocks.filter(\.byClaude).map(hash)
    }

    /// A grey block whose hash Lyra never wrote was edited (in Obsidian), so it is Aidan's now: white.
    public static func settle(_ blocks: [NoteBlock], lyraWrote: [String]) -> [NoteBlock] {
        let known = Set(lyraWrote)
        return blocks.map { block in
            guard block.byClaude, !known.contains(hash(block)) else { return block }
            var mine = block
            mine.byClaude = false
            return mine
        }
    }

    /// My-notes points that no white Expanded block already covers.
    public static func newNotes(myNotes: [NoteBlock], expanded: [NoteBlock]) -> [NoteBlock] {
        let covered = Set(expanded.filter { !$0.byClaude }.map(normalised))
        return myNotes.filter { block in
            let text = normalised(block)
            return !text.isEmpty && !covered.contains(text)
        }
    }

    /// Each new block goes after the Expanded block matching its predecessor in My notes (and that
    /// block's grey children); with no match it goes at the end.
    public static func insertNewNotes(_ new: [NoteBlock], myNotes: [NoteBlock], into expanded: [NoteBlock]) -> [NoteBlock] {
        var result = expanded
        var searchFrom = 0
        for block in new {
            let position = myNotes[searchFrom...].firstIndex(of: block)
            if let position { searchFrom = position + 1 }
            let anchor = position.flatMap { predecessorIndex(before: $0, in: myNotes, matching: result) }
            let at = anchor.map { afterGreyChildren(of: $0, in: result) } ?? result.count
            result.insert(block, at: at)
        }
        return result
    }

    /// Drops Claude's blocks ahead of a fresh expansion.
    public static func stripGrey(_ blocks: [NoteBlock]) -> [NoteBlock] {
        blocks.filter { !$0.byClaude }
    }

    /// Moves a block with its children as one unit. `to` indexes the ORIGINAL array (count = the end);
    /// dropping a unit inside its own span changes nothing.
    public static func moveBlock(_ blocks: [NoteBlock], from: Int, to: Int) -> [NoteBlock] {
        guard blocks.indices.contains(from) else { return blocks }
        let span = unitRange(startingAt: from, in: blocks)
        let target = min(max(to, 0), blocks.count)
        guard target < span.lowerBound || target > span.upperBound else { return blocks }
        var rest = blocks
        let unit = Array(rest[span])
        rest.removeSubrange(span)
        rest.insert(contentsOf: unit, at: target < span.lowerBound ? target : target - unit.count)
        return rest
    }

    // MARK: Helpers

    private static func hash(_ block: NoteBlock) -> String {
        NoteSections.hash(NoteMarkdown.render([block]))
    }

    private static func normalised(_ block: NoteBlock) -> String {
        block.plainText.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Nearest earlier non-blank My-notes line, found in `blocks` (white blocks win over grey ones).
    private static func predecessorIndex(before index: Int, in myNotes: [NoteBlock], matching blocks: [NoteBlock]) -> Int? {
        guard let previous = myNotes[..<index].last(where: { !normalised($0).isEmpty }) else { return nil }
        let text = normalised(previous)
        return blocks.firstIndex { !$0.byClaude && normalised($0) == text }
            ?? blocks.firstIndex { normalised($0) == text }
    }

    private static func afterGreyChildren(of index: Int, in blocks: [NoteBlock]) -> Int {
        var end = index + 1
        while end < blocks.count, blocks[end].byClaude, blocks[end].indent > blocks[index].indent { end += 1 }
        return end
    }

    /// A heading owns everything up to the next heading of the same or higher level; any other block
    /// owns the deeper-indented blocks after it (never a heading).
    private static func unitRange(startingAt start: Int, in blocks: [NoteBlock]) -> Range<Int> {
        let head = blocks[start]
        var end = start + 1
        while end < blocks.count {
            let next = blocks[end]
            switch head.kind {
            case .heading1: if next.kind == .heading1 { return start..<end }
            case .heading2: if next.kind == .heading1 || next.kind == .heading2 { return start..<end }
            default: if next.indent <= head.indent || next.kind == .heading1 || next.kind == .heading2 { return start..<end }
            }
            end += 1
        }
        return start..<end
    }
}
