import AppKit
import LyraCore

/// How note keys look on screen.
enum NoteStyle {
    static let gutter: CGFloat = 60
    static let indentStep: CGFloat = 20
    static let markerWidth: CGFloat = 22
    static let handleWidth: CGFloat = 16
    /// Widest the text column gets; the rest of a wide window is even margin.
    static let maxColumn: CGFloat = 680
    /// A single blank line between two lines of text: a paragraph break, not a whole empty line.
    static let blankLineHeight: CGFloat = 6
    /// Granola's flat warm dark grey (#292929) in dark mode; the normal page white in light mode.
    static let background = NSColor(name: "lyraNoteBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 41 / 255, green: 41 / 255, blue: 41 / 255, alpha: 1) : .textBackgroundColor
    }
    static var body: NSFont { .systemFont(ofSize: 15) }

    static func font(for kind: BlockKind, bold: Bool) -> NSFont {
        switch kind {
        // The big heading is Claude's topic heading (`###` in the file); the small one a sub-heading (`####`).
        case .heading1: .systemFont(ofSize: 18, weight: bold ? .bold : .semibold)
        case .heading2: .systemFont(ofSize: 16, weight: bold ? .bold : .semibold)
        default: bold ? .systemFont(ofSize: 15, weight: .semibold) : body
        }
    }

    static func colour(grey: Bool) -> NSColor { grey ? .secondaryLabelColor : .labelColor }

    /// `text` with fonts, colours and indents drawn from its note keys added to every character.
    static func styled(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            result.setAttributes(display(attrs), range: range)
        }
        attachMedia(in: result)
        compactBlankLines(in: result)
        return result
    }

    /// Each divider's or picture's character drawn as one (its "\n" stays plain text).
    private static func attachMedia(in text: NSMutableAttributedString) {
        let units = text.string as NSString
        var search = NSRange(location: 0, length: units.length)
        while true {
            let found = units.range(of: NoteText.mediaCharacter, range: search)
            guard found.location != NSNotFound else { return }
            let attrs = text.attributes(at: found.location, effectiveRange: nil)
            let kind = NoteText.kind(of: attrs)
            if kind.isMedia {
                text.addAttribute(.attachment, value: NoteMediaAttachment(kind: kind, media: attrs[NoteText.media] as? String), range: found)
            }
            search = NSRange(location: NSMaxRange(found), length: units.length - NSMaxRange(found))
        }
    }

    /// A lone empty paragraph with text on both sides is drawn `blankLineHeight` tall. The blank line stays in the
    /// text (and the file); only its height changes, and typing into it makes an ordinary line again. The editor
    /// gives the one the cursor is on its full height back so there is room to type.
    private static func compactBlankLines(in text: NSMutableAttributedString) {
        for location in gapLocations(in: text.string) {
            text.addAttribute(.paragraphStyle, value: gapStyle, range: NSRange(location: location, length: 1))
        }
    }

    static var gapStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = blankLineHeight
        style.maximumLineHeight = blankLineHeight
        return style
    }

    /// Where each lone blank line between two lines of text starts (its newline). The empty line starting at
    /// `typing` — the one the cursor is on — counts as text: it is about to be, and the gap beside it stays small.
    static func gapLocations(in string: String, typing: Int? = nil) -> [Int] {
        blankLines(in: string).filter { $0.isGap(typing: typing) }.map(\.location)
    }

    /// Where every empty line starts.
    static func blankLineLocations(in string: String) -> [Int] {
        blankLines(in: string).map(\.location)
    }

    private struct BlankLine {
        let location: Int
        let before: (location: Int, isEmpty: Bool)?
        let after: (location: Int, isEmpty: Bool)?

        func isGap(typing: Int?) -> Bool {
            guard location != typing, let before, let after else { return false }
            return (!before.isEmpty || before.location == typing) && (!after.isEmpty || after.location == typing)
        }
    }

    private static func blankLines(in string: String) -> [BlankLine] {
        let lines = string.components(separatedBy: "\n")
        var starts: [Int] = []
        var location = 0
        for line in lines {
            starts.append(location)
            location += (line as NSString).length + 1
        }
        return lines.indices.filter { lines[$0].isEmpty }.map { i in
            BlankLine(location: starts[i],
                      before: i > 0 ? (starts[i - 1], lines[i - 1].isEmpty) : nil,
                      after: i < lines.count - 1 ? (starts[i + 1], lines[i + 1].isEmpty) : nil)
        }
    }

    /// The note keys in `attrs` plus the look they stand for.
    static func display(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let kind = NoteText.kind(of: attrs)
        let indent = attrs[NoteText.indent] as? Int ?? 0
        var result = attrs
        result[.font] = font(for: kind, bold: attrs[NoteText.bold] as? Bool ?? false)
        result[.foregroundColor] = colour(grey: attrs[NoteText.byClaude] as? Bool ?? false)
        result[.underlineStyle] = (attrs[NoteText.underline] as? Bool ?? false) ? NSUnderlineStyle.single.rawValue : 0
        result[.paragraphStyle] = paragraphStyle(kind, indent: indent)
        result[.attachment] = nil  // only `styled` makes attachments, and only on a divider's or picture's own character
        return result
    }

    private static func paragraphStyle(_ kind: BlockKind, indent: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let isList = kind == .bullet || kind == .numbered
        let lead = isList ? CGFloat(indent) * indentStep + markerWidth : 0
        style.firstLineHeadIndent = lead
        style.headIndent = lead
        style.lineSpacing = 5
        switch kind {
        case .heading1: style.paragraphSpacingBefore = 12; style.paragraphSpacing = 4
        case .heading2: style.paragraphSpacingBefore = 10; style.paragraphSpacing = 3
        case .bullet, .numbered: style.paragraphSpacing = 4
        case .paragraph: style.paragraphSpacing = 8
        case .divider: style.paragraphSpacingBefore = 4; style.paragraphSpacing = 8
        case .image: style.paragraphSpacingBefore = 6; style.paragraphSpacing = 12
        }
        return style
    }

    /// Each numbered block's number, counted exactly as the file will write it.
    static func listNumbers(_ blocks: [NoteBlock]) -> [Int] {
        let lines = NoteMarkdown.renderLines(blocks)
        return blocks.indices.map { i in
            guard blocks[i].kind == .numbered, lines.indices.contains(i) else { return 0 }
            return Int(lines[i].drop(while: { $0 == " " }).prefix(while: \.isNumber)) ?? 0
        }
    }
}
