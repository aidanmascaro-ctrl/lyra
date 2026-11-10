import AppKit
import LyraCore

/// A divider or picture in the editor: the one character its block is, drawn by `NoteMediaCell`.
final class NoteMediaAttachment: NSTextAttachment {
    init(kind: BlockKind, media: String?) {
        super.init(data: nil, ofType: nil)
        attachmentCell = MainActor.assumeIsolated { NoteMediaCell(kind: kind, media: media) }  // AppKit builds text on the main thread
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
        let (kind, media) = (kind, media)
        nonisolated(unsafe) let container = textContainer  // AppKit lays text out on the main thread
        return MainActor.assumeIsolated {
            let view = container.textView as? NoteTextView
            return NSRect(origin: .zero, size: Self.size(kind: kind, image: view?.image(for: media), column: column))
        }
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
        case .image: drawPicture(view?.image(for: media), missing: view?.isMissing(media) ?? true, in: cellFrame, selected: selected)
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

    private func drawPicture(_ image: NSImage?, missing: Bool, in frame: NSRect, selected: Bool) {
        let shape = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        if let image {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else if missing {
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

/// Finds and holds the pictures one note shows. Finding a file (which can mean searching the vault) and reading it
/// happen off the main thread; until then a picture is drawn as an empty box, and `onLoaded` fires when it arrives.
/// `reset` looks every picture up again (one added in Obsidian since) while still showing what it had.
@MainActor
final class NoteImageLoader {
    let note: URL
    let vaultRoot: URL
    var onLoaded: (() -> Void)?
    private enum Entry { case loading, found(NSImage), missing }
    private var cache: [String: Entry] = [:]
    private var stale: Set<String> = []

    init(note: URL, vaultRoot: URL) {
        self.note = note
        self.vaultRoot = vaultRoot
    }

    /// The picture for `media` if it has been read; nil while looking or when not found (`isMissing` tells which).
    func image(for media: String) -> NSImage? {
        lookUpIfNeeded(media)
        if case .found(let image) = cache[media] { return image }
        return nil
    }

    func isMissing(_ media: String) -> Bool {
        if case .missing = cache[media] { return true }
        return false
    }

    func reset() { stale = Set(cache.keys) }

    private func lookUpIfNeeded(_ media: String) {
        let known = cache[media]
        if known != nil, !stale.contains(media) { return }
        stale.remove(media)
        if known == nil { cache[media] = .loading }
        guard let target = NoteMarkdown.imageTarget(of: media) else { cache[media] = .missing; return }
        let (note, vault) = (note, vaultRoot)
        Task.detached(priority: .userInitiated) {
            let data = NoteImages.resolve(target, note: note, vaultRoot: vault).flatMap { try? Data(contentsOf: $0) }
            await MainActor.run { [weak self] in self?.loaded(media, data: data) }
        }
    }

    private func loaded(_ media: String, data: Data?) {
        cache[media] = data.flatMap(NSImage.init(data:)).map(Entry.found) ?? .missing
        onLoaded?()
    }
}
