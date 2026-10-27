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
    /// Granola's flat warm dark grey (#292929) in dark mode; the normal page white in light mode.
    static let background = NSColor(name: "lyraNoteBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 41 / 255, green: 41 / 255, blue: 41 / 255, alpha: 1) : .textBackgroundColor
    }
    static var body: NSFont { .systemFont(ofSize: 15) }

    static func font(for kind: BlockKind, bold: Bool) -> NSFont {
        switch kind {
        case .heading1: .systemFont(ofSize: 22, weight: bold ? .bold : .semibold)
        case .heading2: .systemFont(ofSize: 18, weight: bold ? .bold : .semibold)
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
        return result
    }

    /// The note keys in `attrs` plus the look they stand for.
    static func display(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let kind = NoteText.blocks(NSAttributedString(string: "x", attributes: attrs)).first?.kind ?? .paragraph
        let indent = attrs[NoteText.indent] as? Int ?? 0
        var result = attrs
        result[.font] = font(for: kind, bold: attrs[NoteText.bold] as? Bool ?? false)
        result[.foregroundColor] = colour(grey: attrs[NoteText.byClaude] as? Bool ?? false)
        result[.underlineStyle] = (attrs[NoteText.underline] as? Bool ?? false) ? NSUnderlineStyle.single.rawValue : 0
        result[.paragraphStyle] = paragraphStyle(kind, indent: indent)
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
        case .heading1: style.paragraphSpacingBefore = 18; style.paragraphSpacing = 6
        case .heading2: style.paragraphSpacingBefore = 12; style.paragraphSpacing = 4
        case .bullet, .numbered: style.paragraphSpacing = 4
        case .paragraph: style.paragraphSpacing = 8
        }
        return style
    }

    /// Each numbered block's number, counted exactly as the file will write it.
    static func listNumbers(_ blocks: [NoteBlock]) -> [Int] {
        let lines = NoteMarkdown.render(blocks).components(separatedBy: "\n")
        return blocks.indices.map { i in
            guard blocks[i].kind == .numbered, lines.indices.contains(i) else { return 0 }
            return Int(lines[i].drop(while: { $0 == " " }).prefix(while: \.isNumber)) ?? 0
        }
    }
}
