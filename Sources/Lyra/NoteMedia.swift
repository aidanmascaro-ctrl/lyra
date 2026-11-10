import AppKit
import LyraCore

/// A divider or picture in the editor: the one character its block is, drawn by `NoteMediaCell`.
final class NoteMediaAttachment: NSTextAttachment {
    init(kind: BlockKind, media: String?) {
        super.init(data: nil, ofType: nil)
        attachmentCell = NoteMediaCell(kind: kind, media: media)
    }

    required init?(coder: NSCoder) { fatalError("NoteMediaAttachment is built in code") }
}

/// Draws a divider as a thin rule across the column, and a picture at its own size, shrunk to the column when wider.
/// A picture Lyra can't find is a quiet box with its file name.
final class NoteMediaCell: NSTextAttachmentCell {
    let kind: BlockKind
    let media: String?
    static let dividerHeight: CGFloat = 21
    static let missingHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 6

    init(kind: BlockKind, media: String?) {
        self.kind = kind
        self.media = media
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("NoteMediaCell is built in code") }

    var fileName: String {
        media.flatMap(NoteMarkdown.imageTarget(of:)).map { ($0 as NSString).lastPathComponent } ?? "picture"
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let column = max(textContainer.size.width - 2 * textContainer.lineFragmentPadding, 40)
        let view = textContainer.textView as? NoteTextView
        return NSRect(origin: .zero, size: Self.size(kind: kind, image: view?.image(for: media), column: column))
    }

    /// A picture's own size in points, scaled down (never up) to fit `column`.
    static func size(kind: BlockKind, image: NSImage?, column: CGFloat) -> NSSize {
        guard kind == .image else { return NSSize(width: column, height: dividerHeight) }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return NSSize(width: min(column, 320), height: missingHeight)
        }
        let scale = min(1, column / image.size.width)
        return NSSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        let view = controlView as? NoteTextView
        let selected = view.map { NSLocationInRange(charIndex, $0.selectedRange()) && $0.selectedRange().length > 0 } ?? false
        switch kind {
        case .image: drawPicture(view?.image(for: media), in: cellFrame, selected: selected)
        default: drawDivider(in: cellFrame, selected: selected)
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(withFrame: cellFrame, in: controlView, characterIndex: NSNotFound, layoutManager: NSLayoutManager())
    }

    private func drawDivider(in frame: NSRect, selected: Bool) {
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        NSRect(x: frame.minX, y: floor(frame.midY), width: frame.width, height: 1).fill()
    }

    private func drawPicture(_ image: NSImage?, in frame: NSRect, selected: Bool) {
        let shape = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        if let image {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.quaternaryLabelColor.setFill()
            shape.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let text = "Picture not found: \(fileName)" as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(with: NSRect(x: frame.minX + 12, y: frame.midY - size.height / 2, width: frame.width - 24, height: size.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        if selected {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// Finds and holds the pictures one note shows. Each picture line is looked up once (found or not) until `reset`.
@MainActor
final class NoteImageLoader {
    let note: URL
    let vaultRoot: URL
    private var cache: [String: NSImage?] = [:]

    init(note: URL, vaultRoot: URL) {
        self.note = note
        self.vaultRoot = vaultRoot
    }

    func image(for media: String) -> NSImage? {
        if let known = cache[media] { return known }
        let image = NoteMarkdown.imageTarget(of: media)
            .flatMap { NoteImages.resolve($0, note: note, vaultRoot: vaultRoot) }
            .flatMap(NSImage.init(contentsOf:))
        cache[media] = image
        return image
    }

    func reset() { cache = [:] }
}
