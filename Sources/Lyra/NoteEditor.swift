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
        func receive(_ blocks: [NoteBlock]) {
            guard blocks != lastKnown, let textView else { return }
            if unsent { flush(deferred: true); return }
            lastKnown = blocks
            textView.load(blocks)
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

        func textDidEndEditing(_ notification: Notification) { flush() }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        @objc private func appWillTerminate() { flush() }

        @objc private func windowWillClose(_ notification: Notification) {
            if let window = textView?.window, notification.object as? NSWindow === window { flush() }
        }
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
