import AppKit
import LyraCore
import SwiftUI

enum SelectionAction { case expand, find, ask }

/// The note canvas: plain text with bold, underline, two headings, bullets, numbered lists and indent.
/// `blocks` from outside replace the text only when they differ from what the editor last sent out, and not
/// while it holds unsent typing. A new `pushID` marks a push from `NoteSync`: every one is answered through
/// `onExternal(id, shown)`, true when the editor now shows it (or already did), false when unsent typing refused
/// it. Raising `forceLoad` shows `blocks` whatever was typed (Reload). With `editable` off it takes no typing and
/// gives up the keyboard.
struct NoteEditor: NSViewRepresentable {
    var blocks: [NoteBlock]
    var onChange: ([NoteBlock]) -> Void
    var selectionActions = false
    var onSelectionAction: ((SelectionAction, String, Int) -> Void)?
    var pushID = 0
    var onExternal: ((Int, Bool) -> Void)?
    var forceLoad = 0
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView()
        textView.delegate = context.coordinator
        let scroll = Self.makeScrollView(for: textView)
        context.coordinator.textView = textView
        context.coordinator.lastKnown = blocks
        context.coordinator.forced = forceLoad
        context.coordinator.answered = pushID
        textView.load(blocks)
        return scroll
    }

    static func makeScrollView(for textView: NoteTextView) -> NSScrollView {
        let scroll = OverlayScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.setEditable(editable)
        coordinator.textView?.selectionActions = selectionActions && editable
        coordinator.textView?.onSelectionAction = { [weak coordinator] action, text, block in
            coordinator?.parent.onSelectionAction?(action, text, block)
        }
        if forceLoad != coordinator.forced {
            coordinator.forced = forceLoad
            coordinator.answered = pushID
            coordinator.replace(with: blocks)
        } else if pushID != coordinator.answered {
            coordinator.answered = pushID
            let (id, answer) = (pushID, onExternal)
            coordinator.receive(blocks) { shown in answer?(id, shown) }
        } else {
            coordinator.receive(blocks)
        }
    }

    /// Teardown happens inside a SwiftUI update, so the last edits go out just after it.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.flush(deferred: true) }

    /// Sends edits out no later than a second after the first unsent one (so steady typing is saved
    /// too), and straight away when editing ends, the window closes or the app quits.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        weak var textView: NoteTextView?
        /// What the editor last showed from outside or sent out: an equal `blocks` is not a change.
        var lastKnown: [NoteBlock] = []
        var forced = 0
        /// The last push answered (or skipped by a Reload).
        var answered = 0
        private var unsent = false
        private var pendingSave: Task<Void, Never>?
        /// The editor's own undo history (not the window's), so a reload from outside can clear it.
        private let undo = UndoManager()

        init(_ parent: NoteEditor) {
            self.parent = parent
            super.init()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(appWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
            center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        }

        /// Typed words win: with unsent edits the incoming blocks are skipped and the edits go out instead.
        /// `answer` is called on the next turn (never during a view update), and before any typing it flushes.
        func receive(_ blocks: [NoteBlock], answer: ((Bool) -> Void)? = nil) {
            guard blocks != lastKnown, let textView else {
                if let answer { Task { @MainActor in answer(true) } }  // already showing it
                return
            }
            if unsent {
                if let answer { Task { @MainActor in answer(false) } }
                flush(deferred: true)
                return
            }
            lastKnown = blocks
            textView.load(blocks)
            if let answer { Task { @MainActor in answer(true) } }
        }

        /// Reload: shows `blocks`, dropping any unsent typing.
        func replace(with blocks: [NoteBlock]) {
            pendingSave?.cancel()
            pendingSave = nil
            unsent = false
            lastKnown = blocks
            textView?.load(blocks)
        }

        func setEditable(_ editable: Bool) {
            guard let textView, textView.isEditable != editable else { return }
            if !editable, let window = textView.window, window.firstResponder === textView {
                flush(deferred: true)  // this runs inside a view update: the typing goes out on the next turn
                window.makeFirstResponder(nil)
            }
            textView.isEditable = editable
        }

        /// `deferred` sends on the next main-actor turn, for calls made while SwiftUI is updating views;
        /// the bookkeeping is done now either way.
        func flush(deferred: Bool = false) {
            pendingSave?.cancel()
            pendingSave = nil
            guard unsent, let textView else { return }
            unsent = false
            let blocks = textView.blocks
            guard blocks != lastKnown else { return }
            lastKnown = blocks
            let onChange = parent.onChange
            if deferred { Task { @MainActor in onChange(blocks) } } else { onChange(blocks) }
        }

        func textDidChange(_ notification: Notification) {
            guard !unsent else { return }
            unsent = true
            pendingSave = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }

        /// Deferred: focus can be taken away during a view update (a tab switch, streaming starting).
        func textDidEndEditing(_ notification: Notification) { flush(deferred: true) }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        @objc private func appWillTerminate() { flush() }

        @objc private func windowWillClose(_ notification: Notification) {
            if let window = textView?.window, notification.object as? NSWindow === window { flush() }
        }
    }
}

/// Only ever the thin overlay scroller that shows while scrolling, whatever the system setting, so
/// no track strip breaks the page.
///
/// A note scrolled to the very top stays there through a resize: the text re-wrapping on a narrower window would
/// otherwise keep its first line at the top of the view and scroll the page's top padding out of sight.
private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    private var atTop: Bool { contentView.bounds.origin.y <= 0.5 }

    override func setFrameSize(_ newSize: NSSize) {
        let wasAtTop = atTop
        super.setFrameSize(newSize)
        if wasAtTop { keepAtTop() }
    }

    override func tile() {
        let wasAtTop = atTop
        super.tile()
        if wasAtTop { keepAtTop() }
    }

    private func keepAtTop() {
        guard !atTop else { return }
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// The small floating menu over a selection: Expand this · Find in transcript · Ask…
final class SelectionMenu: NSVisualEffectView {
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
