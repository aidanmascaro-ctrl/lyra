import AppKit
import Combine
import LyraCore

/// Lyra's menu-bar item, built by hand in AppKit so a **left click shows or hides the app** and the drop-down menu (the
/// recording controls, ignored apps, Open at Login, Quit) appears only on a **right click**. SwiftUI's `MenuBarExtra`
/// always opens its menu on any click, with no way to split the two, so the item lives here instead.
///
/// The icon mirrors `AppModel`: a waveform when idle, a red dot while recording, a pause glyph when paused.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let loginItem: LoginItem
    private let presence: DockPresence
    private var watch: AnyCancellable?

    init(model: AppModel, loginItem: LoginItem, presence: DockPresence) {
        self.model = model
        self.loginItem = loginItem
        self.presence = presence
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Lyra"
        }
        updateIcon()
        // Any model change may flip the recording icon. `objectWillChange` fires just before the change, so redraw on
        // the next tick, once the new state is in place.
        watch = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            presence.toggleFromMenuBar()  // left click: show Lyra, or hide it if it's already in front
        }
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = item.button else { return }
        let recording = model.isRecording && !model.isPaused
        let symbol = model.isRecording ? (model.isPaused ? "pause.circle.fill" : "record.circle.fill") : "waveform"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lyra")
        // The record dot keeps its red; idle and paused tint with the menu bar like any template image.
        image?.isTemplate = !recording
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: Menu (right click only)

    /// Dropped by the system, exactly where other menu-bar menus drop: the menu is attached for this one click, then
    /// taken off again so the next left click toggles the window. (Popping it up by hand placed it above the icon,
    /// off the top of the screen, so macOS squashed it down with a scroll arrow over the first item.)
    private func showMenu() {
        guard let button = item.button else { return }
        item.menu = buildMenu()
        button.performClick(nil)  // tracks the menu until it closes
        item.menu = nil
    }

    /// The same items the old SwiftUI menu showed, in the same order.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "Open Lyra") { [presence] in presence.reopen() }
        // Stop also covers the few seconds a recording takes to start; the stop is applied once it runs.
        if model.isRecording || model.starting {
            add(menu, "Stop Recording") { [model] in model.stopRecording() }
        } else {
            add(menu, "Start Recording") { [model] in model.recordNewNote() }
        }
        if let live = model.liveMeeting {
            add(menu, "New note — \(live.appName)") { [presence] in presence.open(.meeting(live.folder)) }
        }
        menu.addItem(.separator())
        if model.isRecording {
            if model.isPaused {
                add(menu, "Resume recording") { [model] in model.resumeRecording() }
            } else {
                add(menu, "Pause recording") { [model] in model.pauseRecording() }
            }
        }
        if model.processingCount > 0 { menu.addItem(label("Processing…")) }
        if !model.ignoredList.isEmpty {
            let sub = NSMenu()
            for app in model.ignoredList { add(sub, app.name) { [model] in model.stopIgnoring(app) } }
            let parent = NSMenuItem(title: "Ignored apps", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        if let error = model.lastError { menu.addItem(label(ErrorBrief.menuLine(error))) }
        menu.addItem(.separator())
        let login = add(menu, "Open at Login") { [loginItem] in loginItem.set(!loginItem.state.isOn) }
        login.state = loginItem.state.isOn ? .on : .off
        add(menu, "Quit") { NSApp.terminate(nil) }
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, run: run)
        menu.addItem(item)
        return item
    }

    /// A greyed, non-clickable line (status text, not an action).
    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// An `NSMenuItem` that runs a closure when chosen, so the menu can be built from `AppModel` state inline.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}
