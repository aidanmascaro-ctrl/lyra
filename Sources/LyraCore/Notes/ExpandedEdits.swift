import Foundation

/// What the meeting window does to the Expanded list when Claude answers: answers become grey blocks,
/// placed under a point or at the end, and a reply worked out on an older copy is laid onto the current one.
public enum ExpandedEdits {
    /// Claude's answer as grey blocks, in the note's own formatting.
    public static func greyBlocks(from answer: String) -> [NoteBlock] {
        NoteMarkdown.parse(answer)
            .filter { !$0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { var grey = $0; grey.byClaude = true; return grey }
    }

    /// `new` under the block at `index`, after the grey already hanging off it. Under a list item the answer
    /// becomes deeper bullets (numbered stays numbered); under a heading or paragraph it is left as it is.
    public static func insert(_ new: [NoteBlock], under index: Int, in blocks: [NoteBlock]) -> [NoteBlock] {
        guard blocks.indices.contains(index) else { return append(new, to: blocks) }
        let target = blocks[index]
        let isList = target.kind == .bullet || target.kind == .numbered
        let placed = new.map { block -> NoteBlock in
            guard isList, block.kind != .heading1, block.kind != .heading2 else { return block }
            var child = block
            if child.kind == .paragraph { child.kind = .bullet }
            child.indent = min(target.indent + 1 + block.indent, NoteMarkdown.maxIndent)
            return child
        }
        var end = index + 1
        while end < blocks.count, blocks[end].byClaude, blocks[end].indent > target.indent { end += 1 }
        var result = blocks
        result.insert(contentsOf: placed, at: end)
        return result
    }

    public static func append(_ new: [NoteBlock], to blocks: [NoteBlock]) -> [NoteBlock] { blocks + new }

    /// `result` is `base` with blocks added. Lays those additions onto `current` (Aidan may have typed while
    /// Claude worked): each run goes after the block it followed in `base`, found in `current`; with that block
    /// gone it goes at the end.
    public static func rebase(_ result: [NoteBlock], base: [NoteBlock], onto current: [NoteBlock]) -> [NoteBlock] {
        if current == base { return result }
        var additions: [(after: Int?, blocks: [NoteBlock])] = []
        var b = 0
        for block in result {
            if b < base.count, block == base[b] { b += 1; continue }
            let after = b == 0 ? nil : b - 1
            if let last = additions.last, last.after == after { additions[additions.count - 1].blocks.append(block) }
            else { additions.append((after, [block])) }
        }
        var out = current
        // Back to front, so earlier insert points keep their positions.
        for addition in additions.reversed() {
            guard let after = addition.after else { out.insert(contentsOf: addition.blocks, at: 0); continue }
            if let anchor = out.firstIndex(of: base[after]) {
                var end = anchor + 1
                while end < out.count, out[end].byClaude, out[end].indent > out[anchor].indent { end += 1 }
                out.insert(contentsOf: addition.blocks, at: end)
            } else {
                out.append(contentsOf: addition.blocks)
            }
        }
        return out
    }
}

/// What the bottom bar was asked: a question, or an idea to weave into the Expanded notes.
public enum BarRequest: Equatable, Sendable {
    case ask(String)
    case inject(String)

    private static let injectWords: Set<String> = ["add", "include", "weave"]

    /// Text whose first word is add / include / weave is an idea to inject; anything else is a question.
    public static func parse(_ text: String) -> BarRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let first = trimmed.prefix(while: \.isLetter).lowercased()
        return injectWords.contains(first) ? .inject(trimmed) : .ask(trimmed)
    }
}
