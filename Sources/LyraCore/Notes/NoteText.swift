import Foundation

/// Bridges note blocks and the attributed text an editor holds. One paragraph per block, separated
/// by "\n"; what a block is lives in custom keys, never in the characters (no "- " or "1. " in the text).
///
/// A block's keys sit on its characters and on the "\n" that ends it. An empty last block has no
/// characters of its own, so its keys ride on the "\n" before it under the separate `trailing…` keys.
public enum NoteText {
    public static let blockKind = NSAttributedString.Key("lyraBlockKind")
    public static let indent = NSAttributedString.Key("lyraIndent")
    public static let bold = NSAttributedString.Key("lyraBold")
    public static let underline = NSAttributedString.Key("lyraUnderline")
    public static let byClaude = NSAttributedString.Key("lyraByClaude")
    public static let trailingKind = NSAttributedString.Key("lyraTrailingKind")
    public static let trailingIndent = NSAttributedString.Key("lyraTrailingIndent")
    public static let trailingByClaude = NSAttributedString.Key("lyraTrailingByClaude")

    public static func attributed(_ blocks: [NoteBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            for run in block.runs {
                result.append(NSAttributedString(string: run.text, attributes: attributes(block, run: run)))
            }
            guard i < blocks.count - 1 else { continue }
            var keys = attributes(block, run: InlineRun(text: "\n"))
            let next = blocks[i + 1]
            if i + 1 == blocks.count - 1, next.runs.isEmpty {
                keys[trailingKind] = name(of: next.kind)
                keys[trailingIndent] = next.indent
                keys[trailingByClaude] = next.byClaude
            }
            result.append(NSAttributedString(string: "\n", attributes: keys))
        }
        return result
    }

    public static func blocks(_ text: NSAttributedString) -> [NoteBlock] {
        let string = text.string as NSString
        guard string.length > 0 else { return [] }
        var blocks: [NoteBlock] = []
        var start = 0
        while start <= string.length {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: string.length - start))
            let end = newline.location == NSNotFound ? string.length : newline.location
            blocks.append(block(in: text, range: NSRange(location: start, length: end - start),
                                hasTerminator: newline.location != NSNotFound))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return blocks
    }

    /// An editor's blocks. An empty text has no characters to carry a kind, so a note that is one empty heading or
    /// list item (just made by "- " on the first line) is held by the editor as `emptyBlock`, used only while the
    /// text is empty.
    public static func blocks(_ text: NSAttributedString, emptyBlock: NoteBlock?) -> [NoteBlock] {
        text.length == 0 ? emptyBlock.map { [$0] } ?? [] : blocks(text)
    }

    /// The block an editor showing `blocks` must hold itself: their only block, when it has no characters and is
    /// more than a plain empty line (an empty note is no blocks).
    public static func emptyBlock(of blocks: [NoteBlock]) -> NoteBlock? {
        guard blocks.count == 1, let only = blocks.first, only.runs.isEmpty,
              only != NoteBlock(kind: .paragraph, runs: []) else { return nil }
        return only
    }

    /// The block a typed line prefix turns its line into, and how many characters the shortcut used.
    public static func shortcut(forLinePrefix prefix: String) -> (BlockKind, consumed: Int)? {
        switch prefix {
        case "- ", "* ": return (.bullet, 2)
        case "1. ": return (.numbered, 3)
        case "# ": return (.heading1, 2)
        case "## ": return (.heading2, 3)
        default: return nil
        }
    }

    /// The block Return makes after `block`: a fresh item of the same list (its number follows from
    /// its place), or nil when Return should end the list (an empty item, or not a list at all).
    public static func continuation(after block: NoteBlock) -> NoteBlock? {
        guard block.kind == .bullet || block.kind == .numbered, !block.plainText.isEmpty else { return nil }
        return NoteBlock(kind: block.kind, indent: block.indent, runs: [])
    }

    // MARK: Helpers

    private static func attributes(_ block: NoteBlock, run: InlineRun) -> [NSAttributedString.Key: Any] {
        [blockKind: name(of: block.kind), indent: block.indent, bold: run.bold,
         underline: run.underline, byClaude: block.byClaude]
    }

    private static func block(in text: NSAttributedString, range: NSRange, hasTerminator: Bool) -> NoteBlock {
        var keys: [NSAttributedString.Key: Any] = [:]
        if range.length > 0 || hasTerminator {
            keys = text.attributes(at: range.location, effectiveRange: nil)
        } else if range.location > 0 {
            // An empty last block: only the trailing keys on the "\n" before it describe it.
            let before = text.attributes(at: range.location - 1, effectiveRange: nil)
            keys = [blockKind: before[trailingKind] as Any, indent: before[trailingIndent] as Any,
                    byClaude: before[trailingByClaude] as Any]
        }
        var runs: [InlineRun] = []
        text.enumerateAttributes(in: range) { attrs, sub, _ in
            let piece = (text.string as NSString).substring(with: sub)
            let isBold = attrs[bold] as? Bool ?? false, isUnderline = attrs[underline] as? Bool ?? false
            if let last = runs.last, last.bold == isBold, last.underline == isUnderline {
                runs[runs.count - 1].text += piece
            } else {
                runs.append(InlineRun(text: piece, bold: isBold, underline: isUnderline))
            }
        }
        return NoteBlock(kind: kind(named: keys[blockKind] as? String), indent: keys[indent] as? Int ?? 0,
                         runs: runs, byClaude: keys[byClaude] as? Bool ?? false)
    }

    private static func name(of kind: BlockKind) -> String {
        switch kind {
        case .paragraph: "paragraph"
        case .heading1: "heading1"
        case .heading2: "heading2"
        case .bullet: "bullet"
        case .numbered: "numbered"
        }
    }

    private static func kind(named name: String?) -> BlockKind {
        switch name {
        case "heading1": .heading1
        case "heading2": .heading2
        case "bullet": .bullet
        case "numbered": .numbered
        default: .paragraph
        }
    }
}
