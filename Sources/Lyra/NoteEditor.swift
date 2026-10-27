import AppKit
import LyraCore
import SwiftUI

enum SelectionAction { case expand, find, ask }

/// The note canvas: plain text with bold, underline, two headings, bullets, numbered lists and indent.
/// `blocks` from outside replace the text only when they differ from what the editor last sent out.
struct NoteEditor: NSViewRepresentable {
    var blocks: [NoteBlock]
    var onChange: ([NoteBlock]) -> Void
    var selectionActions = false
    var onSelectionAction: ((SelectionAction, String, Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView()
        textView.delegate = context.coordinator
        let scroll = OverlayScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        context.coordinator.textView = textView
        context.coordinator.lastKnown = blocks
        textView.load(blocks)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.textView?.selectionActions = selectionActions
        coordinator.textView?.onSelectionAction = { [weak coordinator] action, text, block in
            coordinator?.parent.onSelectionAction?(action, text, block)
        }
        coordinator.receive(blocks)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.flush() }

    /// Sends edits out at most once a second, and straight away when editing ends or the view goes.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        weak var textView: NoteTextView?
        /// What the editor last showed from outside or sent out: an equal `blocks` is not a change.
        var lastKnown: [NoteBlock] = []
        private var unsent = false
        private var debounce: Task<Void, Never>?

        init(_ parent: NoteEditor) { self.parent = parent }

        /// Typed words win: with unsent edits the incoming blocks are skipped and the edits go out instead.
        func receive(_ blocks: [NoteBlock]) {
            guard blocks != lastKnown, let textView else { return }
            if unsent { flush(); return }
            lastKnown = blocks
            textView.load(blocks)
        }

        func flush() {
            debounce?.cancel()
            guard unsent, let textView else { return }
            unsent = false
            let blocks = textView.blocks
            guard blocks != lastKnown else { return }
            lastKnown = blocks
            parent.onChange(blocks)
        }

        func textDidChange(_ notification: Notification) {
            unsent = true
            debounce?.cancel()
            debounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }

        func textDidEndEditing(_ notification: Notification) { flush() }
    }
}

/// The text view behind `NoteEditor`. Every block property lives in `NoteText`'s keys; fonts, colours
/// and indents are drawn from them, and list markers and drag handles are painted, never typed.
final class NoteTextView: NSTextView {
    var selectionActions = false { didSet { updateSelectionMenu() } }
    var onSelectionAction: ((SelectionAction, String, Int) -> Void)?

    /// Where the last typing landed (in the new text), so the blocks it touched can turn white.
    private var typedRange: NSRange?
    private var programmatic = false
    private var hoveredBlock: Int?
    private var drag: (from: Int, to: Int)?
    private lazy var selectionMenu = SelectionMenu { [weak self] action in self?.runSelectionAction(action) }

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = true
        allowsUndo = true
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        isAutomaticDashSubstitutionEnabled = false
        drawsBackground = true
        backgroundColor = NoteStyle.background
        insertionPointColor = .labelColor
        textContainerInset = NSSize(width: NoteStyle.gutter, height: 28)
        isVerticallyResizable = true
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    required init?(coder: NSCoder) { fatalError("NoteTextView is built in code") }

    /// At least as tall as the scroll view, so a click anywhere below the text still lands in it, and
    /// the text column centred at no wider than `NoteStyle.maxColumn` so wide windows keep a calm line length.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, enclosingScrollView?.contentSize.height ?? 0)))
        let side = max(NoteStyle.gutter, (newSize.width - NoteStyle.maxColumn) / 2)
        if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: textContainerInset.height) }
    }

    var blocks: [NoteBlock] { NoteText.blocks(textStorage ?? NSTextStorage()) }

    /// Shows `blocks` without an undo step, keeping the caret where it was as far as the text allows.
    func load(_ blocks: [NoteBlock]) {
        guard let storage = textStorage else { return }
        let caret = selectedRange()
        undoManager?.removeAllActions(withTarget: storage)
        undoManager?.removeAllActions(withTarget: self)
        storage.setAttributedString(NoteStyle.styled(NoteText.attributed(blocks)))
        let location = min(caret.location, storage.length)
        setSelectedRange(NSRange(location: location, length: min(caret.length, storage.length - location)))
        refreshTyping()
        needsDisplay = true
    }

    // MARK: Editing

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: range, replacementString: replacementString) else { return false }
        let replaying = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if !programmatic, !replaying { typedRange = NSRange(location: range.location, length: (replacementString ?? "").utf16.count) }
        return true
    }

    /// Re-applies each touched block's keys across its whole paragraph (typing at a block's edge can
    /// borrow a neighbour's), clears grey where Aidan typed, then restyles.
    override func didChangeText() {
        if let typed = typedRange, let storage = textStorage {
            var blocks = self.blocks
            let touched = paragraphs(covering: typed)
            for i in touched where blocks.indices.contains(i) { blocks[i].byClaude = false }
            restyle(blocks, in: (storage.string as NSString).paragraphRange(for: typed))
        }
        typedRange = nil
        refreshTyping()
        needsDisplay = true
        super.didChangeText()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if (string as? String) == " ", selectedRange().length == 0, applyShortcut() { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Return splits the block; on a list item the new line continues the list, and on an empty item it ends it.
    override func insertNewline(_ sender: Any?) {
        let caret = selectedRange()
        guard caret.length == 0 else { return super.insertNewline(sender) }
        var blocks = self.blocks
        guard !blocks.isEmpty else { return super.insertNewline(sender) }
        let i = blockIndex(at: caret.location), start = blockStart(i, in: blocks), block = blocks[i]
        let isList = block.kind == .bullet || block.kind == .numbered
        if isList, NoteText.continuation(after: block) == nil {
            blocks[i] = NoteBlock(kind: .paragraph, runs: block.runs)
            return replace(with: blocks, caret: caret.location)
        }
        let (head, tail) = split(i, at: caret.location - start)
        var next = NoteText.continuation(after: block) ?? NoteBlock(kind: .paragraph, runs: [])
        if !tail.isEmpty {
            next = NoteBlock(kind: block.kind, indent: block.indent, runs: tail, byClaude: block.byClaude)
        }
        blocks[i].runs = head
        blocks.insert(next, at: i + 1)
        replace(with: blocks, caret: blockStart(i + 1, in: blocks))
    }

    /// Backspace at the start of a list item or heading turns it back into plain text first.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        var blocks = self.blocks
        if caret.length == 0, !blocks.isEmpty {
            let i = blockIndex(at: caret.location)
            if caret.location == blockStart(i, in: blocks), blocks[i].kind != .paragraph {
                blocks[i] = NoteBlock(kind: .paragraph, runs: blocks[i].runs, byClaude: blocks[i].byClaude)
                return replace(with: blocks, caret: caret.location)
            }
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) { shiftIndent(by: 1) }
    override func insertBacktab(_ sender: Any?) { shiftIndent(by: -1) }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (flags, event.charactersIgnoringModifiers?.lowercased(), event.keyCode) {
        case (.command, "b", _): toggle(NoteText.bold); return true
        case (.command, "u", _): toggle(NoteText.underline); return true
        case let (f, _, code) where f.contains([.command, .option]) && (code == 126 || code == 125):
            moveCurrentBlock(up: code == 126); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func applyShortcut() -> Bool {
        var blocks = self.blocks
        let caret = selectedRange().location
        guard !blocks.isEmpty else { return false }
        let i = blockIndex(at: caret), start = blockStart(i, in: blocks)
        let prefix = (string as NSString).substring(with: NSRange(location: start, length: caret - start))
        guard let (kind, consumed) = NoteText.shortcut(forLinePrefix: prefix + " ") else { return false }
        let rest = split(i, at: consumed - 1).tail
        blocks[i] = NoteBlock(kind: kind, indent: blocks[i].indent, runs: rest)
        replace(with: blocks, caret: start)
        return true
    }

    private func shiftIndent(by step: Int) {
        let blocks = self.blocks
        guard !blocks.isEmpty else { return }
        let sel = selectedRange()
        let range = blockIndex(at: sel.location)...blockIndex(at: max(NSMaxRange(sel) - 1, sel.location))
        let moved = blocks.enumerated().map { i, block -> NoteBlock in
            guard range.contains(i), block.kind == .bullet || block.kind == .numbered else { return block }
            var b = block; b.indent = min(max(block.indent + step, 0), NoteMarkdown.maxIndent); return b
        }
        guard moved != blocks else { return }
        replace(with: moved, selection: sel)
    }

    private func toggle(_ key: NSAttributedString.Key) {
        let sel = selectedRange()
        guard sel.length > 0, let storage = textStorage else {
            typingAttributes[key] = !(typingAttributes[key] as? Bool ?? false)
            typingAttributes = NoteStyle.display(typingAttributes)
            return
        }
        var allOn = true
        storage.enumerateAttribute(key, in: sel) { value, sub, _ in
            if !(value as? Bool ?? false), (storage.string as NSString).substring(with: sub) != "\n" { allOn = false }
        }
        let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: sel))
        piece.addAttribute(key, value: !allOn, range: NSRange(location: 0, length: piece.length))
        edit(sel, with: NoteStyle.styled(piece))
        setSelectedRange(sel)
    }

    /// ⌥⌘↑ swaps the block (with what hangs off it) with the sibling above; ⌥⌘↓ with the one below.
    /// A heading swaps with the neighbouring heading of its size; other blocks stay inside their heading.
    private func moveCurrentBlock(up: Bool) {
        let blocks = self.blocks
        guard !blocks.isEmpty else { return }
        let caret = selectedRange().location
        let i = blockIndex(at: caret), offset = caret - blockStart(i, in: blocks)
        func isSibling(_ other: NoteBlock) -> Bool {
            isHeading(blocks[i]) ? other.kind == blocks[i].kind : other.indent == blocks[i].indent && !isHeading(other)
        }
        if up {
            let stop: (NoteBlock) -> Bool = isHeading(blocks[i])
                ? { self.isHeading($0) && ($0.kind == .heading1 || $0.kind == blocks[i].kind) }
                : { $0.indent <= blocks[i].indent }
            guard let j = blocks[..<i].lastIndex(where: stop), isSibling(blocks[j]) else { return }
            let moved = ExpandedMerge.moveBlock(blocks, from: i, to: j)
            replace(with: moved, caret: blockStart(j, in: moved) + offset)
        } else {
            let next = ExpandedMerge.unitRange(startingAt: i, in: blocks).upperBound
            guard next < blocks.count, isSibling(blocks[next]) else { return }
            let nextLength = ExpandedMerge.unitRange(startingAt: next, in: blocks).count
            let moved = ExpandedMerge.moveBlock(blocks, from: next, to: i)
            replace(with: moved, caret: blockStart(i + nextLength, in: moved) + offset)
        }
    }

    private func isHeading(_ block: NoteBlock) -> Bool { block.kind == .heading1 || block.kind == .heading2 }

    /// One undoable step that swaps the whole text for `blocks`; Lyra's own changes never whiten grey.
    private func replace(with blocks: [NoteBlock], caret: Int) {
        replace(with: blocks, selection: NSRange(location: caret, length: 0))
    }

    private func replace(with blocks: [NoteBlock], selection: NSRange) {
        guard let storage = textStorage else { return }
        edit(NSRange(location: 0, length: storage.length), with: NoteStyle.styled(NoteText.attributed(blocks)))
        let location = min(selection.location, storage.length)
        setSelectedRange(NSRange(location: location, length: min(selection.length, storage.length - location)))
        refreshTyping()
    }

    private func edit(_ range: NSRange, with text: NSAttributedString) {
        programmatic = true
        defer { programmatic = false }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    /// Writes `blocks`' keys and styling over the characters in `range` (the text itself is unchanged).
    private func restyle(_ blocks: [NoteBlock], in range: NSRange) {
        guard let storage = textStorage else { return }
        let fresh = NoteStyle.styled(NoteText.attributed(blocks))
        guard fresh.string == storage.string else { return }
        let target = NSRange(location: max(range.location - 1, 0), length: min(range.length + 1, storage.length - max(range.location - 1, 0)))
        storage.beginEditing()
        fresh.enumerateAttributes(in: target) { attrs, sub, _ in storage.setAttributes(attrs, range: sub) }
        storage.endEditing()
    }

    /// New typing takes the current block's keys, not grey, and the style of the character before it.
    private func refreshTyping() {
        let blocks = self.blocks
        let caret = selectedRange().location
        guard let storage = textStorage, !blocks.isEmpty else {
            typingAttributes = NoteStyle.display(NoteText.attributed([NoteBlock(kind: .paragraph, runs: [.init(text: " ")])])
                .attributes(at: 0, effectiveRange: nil))
            return
        }
        let i = blockIndex(at: caret), start = blockStart(i, in: blocks)
        var attrs = NoteText.attributed([NoteBlock(kind: blocks[i].kind, indent: blocks[i].indent, runs: [.init(text: " ")])])
            .attributes(at: 0, effectiveRange: nil)
        let source = caret > start ? caret - 1 : (blocks[i].runs.isEmpty ? nil : caret)
        if let source, source < storage.length {
            attrs[NoteText.bold] = storage.attribute(NoteText.bold, at: source, effectiveRange: nil) ?? false
            attrs[NoteText.underline] = storage.attribute(NoteText.underline, at: source, effectiveRange: nil) ?? false
        }
        typingAttributes = NoteStyle.display(attrs)
    }

    // MARK: Geometry

    private func blockIndex(at location: Int) -> Int {
        let s = string as NSString
        var count = 0, index = 0
        while index < min(location, s.length) {
            let r = s.range(of: "\n", range: NSRange(location: index, length: min(location, s.length) - index))
            guard r.location != NSNotFound else { break }
            count += 1; index = r.location + 1
        }
        return count
    }

    private func blockStart(_ i: Int, in blocks: [NoteBlock]) -> Int {
        blocks.prefix(i).reduce(0) { $0 + $1.plainText.utf16.count + 1 }
    }

    private func paragraphs(covering range: NSRange) -> ClosedRange<Int> {
        blockIndex(at: range.location)...blockIndex(at: NSMaxRange(range))
    }

    private func split(_ i: Int, at offset: Int) -> (head: [InlineRun], tail: [InlineRun]) {
        guard let storage = textStorage else { return ([], []) }
        let start = blockStart(i, in: blocks), length = blocks[i].plainText.utf16.count
        let cut = min(max(offset, 0), length)
        func runs(_ r: NSRange) -> [InlineRun] { NoteText.blocks(storage.attributedSubstring(from: r)).first?.runs ?? [] }
        return (runs(NSRange(location: start, length: cut)), runs(NSRange(location: start + cut, length: length - cut)))
    }

    /// The first line of block `i`, in view coordinates.
    private func lineRect(ofBlock i: Int, in blocks: [NoteBlock]) -> (rect: NSRect, baseline: CGFloat)? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        let start = blockStart(i, in: blocks)
        let origin = textContainerOrigin
        if start >= storage.length {
            layout.ensureLayout(for: container)
            let extra = layout.extraLineFragmentRect
            guard extra.height > 0 else { return nil }
            return (extra.offsetBy(dx: origin.x, dy: origin.y), extra.minY + origin.y + NoteStyle.font(for: blocks[i].kind, bold: false).ascender)
        }
        let glyph = layout.glyphIndexForCharacter(at: start)
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let base = layout.location(forGlyphAt: glyph).y
        return (rect.offsetBy(dx: origin.x, dy: origin.y), rect.minY + origin.y + base)
    }

    private func handleRect(ofBlock i: Int, in blocks: [NoteBlock]) -> NSRect? {
        guard let line = lineRect(ofBlock: i, in: blocks) else { return nil }
        let x = textContainerOrigin.x + CGFloat(blocks[i].indent) * NoteStyle.indentStep - NoteStyle.handleWidth - 4
        return NSRect(x: x, y: line.baseline - 14, width: NoteStyle.handleWidth, height: 18)
    }

    /// The block boundary (0...count) nearest a point: where a dragged block would land.
    private func dropIndex(at point: NSPoint, in blocks: [NoteBlock]) -> Int {
        for i in blocks.indices {
            guard let line = lineRect(ofBlock: i, in: blocks) else { continue }
            if point.y < line.rect.midY { return i }
        }
        return blocks.count
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let blocks = self.blocks
        let numbers = NoteStyle.listNumbers(blocks)
        for i in blocks.indices where blocks[i].kind == .bullet || blocks[i].kind == .numbered {
            guard let line = lineRect(ofBlock: i, in: blocks), line.rect.intersects(dirtyRect) else { continue }
            let marker = blocks[i].kind == .bullet ? "•" : "\(numbers[i])."
            let attrs: [NSAttributedString.Key: Any] = [.font: NoteStyle.body,
                                                        .foregroundColor: NoteStyle.colour(grey: blocks[i].byClaude)]
            let size = (marker as NSString).size(withAttributes: attrs)
            let right = textContainerOrigin.x + CGFloat(blocks[i].indent) * NoteStyle.indentStep + NoteStyle.markerWidth - 8
            (marker as NSString).draw(at: NSPoint(x: right - size.width, y: line.baseline - NoteStyle.body.ascender), withAttributes: attrs)
        }
        if let hovered = drag?.from ?? hoveredBlock, blocks.indices.contains(hovered), let rect = handleRect(ofBlock: hovered, in: blocks) {
            ("⋮⋮" as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                                                               .foregroundColor: NSColor.tertiaryLabelColor])
        }
        if let drag {
            let y = drag.to < blocks.count ? lineRect(ofBlock: drag.to, in: blocks)?.rect.minY : lineRect(ofBlock: blocks.count - 1, in: blocks)?.rect.maxY
            if let y {
                NSColor.controlAccentColor.setFill()
                NSRect(x: textContainerOrigin.x, y: y - 1, width: bounds.width - textContainerOrigin.x * 2, height: 2).fill()
            }
        }
    }

    // MARK: Drag to reorder

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["lyra"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["lyra": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let blocks = self.blocks
        var hovered: Int?
        if let layout = layoutManager, let container = textContainer, !blocks.isEmpty {
            let inContainer = NSPoint(x: max(point.x - textContainerOrigin.x, 0), y: point.y - textContainerOrigin.y)
            let index = layout.characterIndex(for: inContainer, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let candidate = blockIndex(at: index)
            if let line = lineRect(ofBlock: candidate, in: blocks), point.y >= line.rect.minY - 4,
               !blocks[candidate].runs.isEmpty { hovered = candidate }
        }
        if hovered != hoveredBlock { hoveredBlock = hovered; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if drag == nil, hoveredBlock != nil { hoveredBlock = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let blocks = self.blocks
        guard let from = hoveredBlock, blocks.indices.contains(from),
              let handle = handleRect(ofBlock: from, in: blocks), handle.insetBy(dx: -4, dy: -4).contains(point)
        else { return super.mouseDown(with: event) }
        drag = (from, from)
        NSCursor.closedHand.push()
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            drag?.to = dropIndex(at: convert(next.locationInWindow, from: nil), in: blocks)
            needsDisplay = true
        }
        NSCursor.pop()
        let to = drag?.to ?? from
        drag = nil
        let moved = ExpandedMerge.moveBlock(blocks, from: from, to: to)
        if moved != blocks {
            let landed = to < from ? to : to - ExpandedMerge.unitRange(startingAt: from, in: blocks).count
            replace(with: moved, caret: blockStart(landed, in: moved))
        }
        needsDisplay = true
    }

    // MARK: Selection menu

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if stillSelecting { selectionMenu.isHidden = true; return }
        if selectedRange().length == 0 { refreshTyping() }
        updateSelectionMenu()
    }

    private func updateSelectionMenu() {
        let sel = selectedRange()
        guard selectionActions, sel.length > 0, let layout = layoutManager, let container = textContainer else {
            selectionMenu.isHidden = true
            return
        }
        if selectionMenu.superview !== self { addSubview(selectionMenu) }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: sel.location, length: 1), actualCharacterRange: nil)
        let first = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let size = selectionMenu.fittingSize
        let x = min(max(first.minX, 8), bounds.width - size.width - 8)
        let y = first.minY - size.height - 6 < visibleRect.minY ? first.maxY + 6 : first.minY - size.height - 6
        selectionMenu.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        selectionMenu.isHidden = false
    }

    private func runSelectionAction(_ action: SelectionAction) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        selectionMenu.isHidden = true
        onSelectionAction?(action, (string as NSString).substring(with: sel), blockIndex(at: sel.location))
    }
}

/// Only ever the thin overlay scroller that shows while scrolling, whatever the system setting, so
/// no track strip breaks the page.
private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// The small floating menu over a selection: Expand this · Find in transcript · Ask…
private final class SelectionMenu: NSVisualEffectView {
    private let onPick: (SelectionAction) -> Void

    init(onPick: @escaping (SelectionAction) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        material = .menu
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        isHidden = true
        let buttons = [("Expand this", 0), ("Find in transcript", 1), ("Ask…", 2)].map { title, tag in
            let button = NSButton(title: title, target: self, action: #selector(pick(_:)))
            button.isBordered = false
            button.tag = tag
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = .labelColor
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("SelectionMenu is built in code") }

    @objc private func pick(_ sender: NSButton) {
        onPick([SelectionAction.expand, .find, .ask][sender.tag])
    }
}

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
