import Foundation

/// A stretch of text with one style. Only bold and underline exist; anything else stays literal text.
public struct InlineRun: Equatable, Codable, Sendable {
    public var text: String
    public var bold: Bool
    public var underline: Bool

    public init(text: String, bold: Bool = false, underline: Bool = false) {
        self.text = text; self.bold = bold; self.underline = underline
    }
}

public enum BlockKind: Equatable, Codable, Sendable { case paragraph, heading1, heading2, bullet, numbered }

/// One line of a note. `byClaude` blocks are the grey ones: wrapped in `<span class="lyra">` in the file.
public struct NoteBlock: Equatable, Codable, Sendable {
    public var kind: BlockKind
    /// 0...3, two spaces per level in the file.
    public var indent: Int
    public var runs: [InlineRun]
    public var byClaude: Bool

    public var plainText: String { runs.map(\.text).joined() }

    public init(kind: BlockKind, indent: Int = 0, runs: [InlineRun], byClaude: Bool = false) {
        self.kind = kind; self.indent = min(max(indent, 0), NoteMarkdown.maxIndent)
        self.runs = runs; self.byClaude = byClaude
    }
}

/// The small Markdown dialect a note is written in: `**bold**`, `<u>underline</u>`, `### `, `#### `, `- `, `1. `.
/// Anything else is kept as literal paragraph text, so a note Aidan edits elsewhere survives a round trip.
///
/// A heading is written two levels under its section's `##` (so Obsidian's outline nests it and the section folds
/// as one); `# ` and `## `, which notes written before that used, still read as the same two headings.
public enum NoteMarkdown {
    public static let maxIndent = 3
    static let heading1Marker = "### "
    static let heading2Marker = "#### "
    static let oldHeading1Marker = "# "
    static let oldHeading2Marker = "## "
    /// Every marker a heading was ever written with, longest first.
    static let headingMarkers = [heading2Marker, heading1Marker, oldHeading2Marker, oldHeading1Marker]
    private static let claudeOpen = "<span class=\"lyra\">"
    private static let claudeClose = "</span>"

    public static func parse(_ md: String) -> [NoteBlock] {
        guard !md.isEmpty else { return [] }
        return md.components(separatedBy: "\n").map(parseLine)
    }

    /// The note as Markdown. A heading Claude added gets a blank line before it when it would otherwise sit
    /// straight under text; Aidan's own lines are written exactly as they are.
    public static func render(_ blocks: [NoteBlock]) -> String {
        let lines = renderLines(blocks)
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            if i > 0, needsGapBefore(blocks[i], after: blocks[i - 1]) { out.append("") }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// One line per block, with no blank lines added. Numbered items count up from 1 within a run at one
    /// indent; any other block at that indent or shallower restarts it.
    public static func renderLines(_ blocks: [NoteBlock]) -> [String] {
        var counters = [Int](repeating: 0, count: maxIndent + 1)
        return blocks.map { block in
            let level = min(max(block.indent, 0), maxIndent)
            let resetFrom = block.kind == .numbered ? level + 1 : level
            for i in resetFrom..<counters.count { counters[i] = 0 }
            if block.kind == .paragraph || block.kind == .heading1 || block.kind == .heading2 {
                counters = [Int](repeating: 0, count: maxIndent + 1)
            }
            var marker = ""
            switch block.kind {
            case .paragraph: break
            case .heading1: marker = heading1Marker
            case .heading2: marker = heading2Marker
            case .bullet: marker = String(repeating: "  ", count: level) + "- "
            case .numbered:
                counters[level] += 1
                marker = String(repeating: "  ", count: level) + "\(counters[level]). "
            }
            let inline = renderRuns(block.runs)
            return marker + (block.byClaude ? claudeOpen + inline + claudeClose : inline)
        }
    }

    private static func needsGapBefore(_ block: NoteBlock, after previous: NoteBlock) -> Bool {
        let isHeading = block.kind == .heading1 || block.kind == .heading2
        return isHeading && block.byClaude && !previous.plainText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Lines

    private static func parseLine(_ line: String) -> NoteBlock {
        let (kind, indent, content) = splitMarker(line)
        var body = content
        var byClaude = false
        if body.hasPrefix(claudeOpen), body.hasSuffix(claudeClose) {
            let inner = body.dropFirst(claudeOpen.count).dropLast(claudeClose.count)
            if !inner.contains(claudeOpen) && !inner.contains(claudeClose) {
                body = String(inner); byClaude = true
            }
        }
        return NoteBlock(kind: kind, indent: indent, runs: parseRuns(body), byClaude: byClaude)
    }

    private static func splitMarker(_ line: String) -> (BlockKind, Int, String) {
        for marker in headingMarkers where line.hasPrefix(marker) {
            let kind: BlockKind = marker == heading1Marker || marker == oldHeading1Marker ? .heading1 : .heading2
            return (kind, 0, String(line.dropFirst(marker.count)))
        }
        let spaces = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(spaces)
        let indent = min(spaces / 2, maxIndent)
        if rest.hasPrefix("- ") { return (.bullet, indent, String(rest.dropFirst(2))) }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return (.numbered, indent, String(rest.dropFirst(digits.count + 2)))
        }
        return (.paragraph, 0, line)
    }

    // MARK: Inline

    /// `**` and `<u>` only open a style when a closer follows on the line; a stray one stays literal text.
    private static func parseRuns(_ text: String) -> [InlineRun] {
        var runs: [InlineRun] = []
        var buffer = ""
        var bold = false, underline = false
        func flush() {
            guard !buffer.isEmpty else { return }
            if let last = runs.last, last.bold == bold, last.underline == underline {
                runs[runs.count - 1].text += buffer
            } else {
                runs.append(InlineRun(text: buffer, bold: bold, underline: underline))
            }
            buffer = ""
        }
        var rest = Substring(text)
        while let ch = rest.first {
            if rest.hasPrefix("**"), bold || rest.dropFirst(2).contains("**") {
                flush(); bold.toggle(); rest = rest.dropFirst(2)
            } else if !underline, rest.hasPrefix("<u>"), rest.dropFirst(3).contains("</u>") {
                flush(); underline = true; rest = rest.dropFirst(3)
            } else if underline, rest.hasPrefix("</u>") {
                flush(); underline = false; rest = rest.dropFirst(4)
            } else {
                buffer.append(ch); rest = rest.dropFirst()
            }
        }
        flush()
        return runs
    }

    private static func renderRuns(_ runs: [InlineRun]) -> String {
        runs.map { run in
            var s = run.text
            if run.underline { s = "<u>" + s + "</u>" }
            if run.bold { s = "**" + s + "**" }
            return s
        }.joined()
    }
}
