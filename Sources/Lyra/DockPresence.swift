import AppKit
import LyraCore
import SwiftUI

/// Lyra is a Dock app (Dock icon, ⌘-Tab, app menu) while any of its windows is open, and menu-bar-only once the
/// last one closes; `DockPolicy` decides. Info.plist's `LSUIElement` makes it start menu-bar-only. Recording,
/// detection and processing don't depend on any of this.
@MainActor
final class DockPresence: NSObject {
    /// Opens Lyra's main window through SwiftUI's `openWindow`. Set by `MainWindowOpener` from the main window itself
    /// (shown at every launch), so it is there once that window has appeared.
    var openMain: (() -> Void)?
    private let app: AppModel
    /// Windows told to close that may still report visible; dropped a turn later, once they are really gone.
    private var closing: Set<Int> = []

    init(app: AppModel) { self.app = app }

    func start() {
        let center = NotificationCenter.default
        // A window coming on screen (occlusion changes then) or forward makes Lyra a Dock app; closing may end it.
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    /// The Dock icon clicked, or Lyra opened again: minimised windows come back, open ones come forward, and with
    /// none open, the main window opens on home.
    func reopen() {
        switch DockPolicy.reopen(Self.describe(NSApp.windows), closing: closing) {
        case .openHome:
            showHome()
        case .front(let restore):
            for window in NSApp.windows where restore.contains(window.windowNumber) { window.deminiaturize(nil) }
            // A minimised window first; otherwise the open main window, which may just be behind other apps' windows
            // (the Dock activates Lyra itself, but a menu-bar click doesn't, so the window is fronted here).
            let target = NSApp.windows.first { $0.windowNumber == restore.first }
                ?? NSApp.windows.first { Self.isMain($0) && $0.isVisible }
            target?.makeKeyAndOrderFront(nil)
            activate()
        }
    }

    /// The menu-bar icon left-clicked on `screen`'s menu bar: hides Lyra when it is already in front, otherwise brings
    /// it forward on that display (moving the window across if it is on another one). Hiding keeps the page it was
    /// on, so the next click shows that same page.
    func toggleFromMenuBar(on screen: NSScreen?) {
        let decision = DockPolicy.menuBarClick(Self.describe(NSApp.windows), closing: closing, isActive: NSApp.isActive,
                                               isHidden: NSApp.isHidden)
        switch decision {
        case .hide:
            NSApp.hide(nil)
        case .show:
            // Unhidden first: asking to come forward while still hidden was ignored (seen in testing: the click after
            // a hide left the other app in front). Then activated now, while the click is still the current event:
            // macOS lets an app come forward in answer to the user's own click and may refuse a later request. The
            // older call is the fallback many menu-bar apps still rely on when the newer, polite one is declined.
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate()
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            reopen()
            if let screen, let window = NSApp.windows.first(where: { Self.isMain($0) && $0.isVisible }), window.screen != screen {
                let v = screen.visibleFrame
                let f = DockPolicy.place(width: window.frame.width, height: window.frame.height,
                                         on: .init(x: v.minX, y: v.minY, width: v.width, height: v.height))
                window.setFrame(NSRect(x: f.x, y: f.y, width: f.width, height: f.height), display: true)
            }
        }
    }

    /// The main window on home, through SwiftUI when it has handed over `openWindow`; otherwise a main window
    /// AppKit still holds.
    private func showHome() {
        open(.home)
    }

    /// Opens Lyra's one window on `route` and brings it forward. The menu-bar item uses this for a left click (home)
    /// and for "New note" (the live meeting); the window re-reads `route` as it comes on screen.
    func open(_ route: Route) {
        app.route = route
        if let openMain { openMain() } else { NSApp.windows.first(where: Self.isMain)?.makeKeyAndOrderFront(nil) }
        activate()
    }

    @objc private func windowChanged() { update() }

    @objc private func windowBecameKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { closing.remove(window.windowNumber) }  // reopened
        update()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let number = window.windowNumber
        closing.insert(number)
        // Closed on a meeting: it opens on home next time. The meeting's editors flush as the window goes.
        if Self.isMain(window) { app.route = .home }
        update()
        // Checked again once the close has finished, so a late occlusion or key change can't leave a Dock icon
        // with no window.
        Task { @MainActor [weak self] in
            self?.closing.remove(number)
            self?.update()
        }
    }

    private func update(retry: Bool = true) {
        // Hidden (menu-bar click or ⌘H), its windows report not visible, but it is still open: keep the Dock icon,
        // as any hidden app does, rather than drop back to menu-bar-only.
        guard !NSApp.isHidden else { return }
        let policy: NSApplication.ActivationPolicy = DockPolicy.showsInDock(Self.describe(NSApp.windows), closing: closing)
            ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        guard NSApp.setActivationPolicy(policy) else {
            // Refused (seen once just after a relaunch): try again once the run loop has turned.
            if retry { Task { @MainActor [weak self] in self?.update(retry: false) } }
            return
        }
        // A window just appeared because Aidan asked for it: bring it forward. The last one closed: give the
        // keyboard back to whatever he was using.
        if policy == .regular { activate() } else { NSApp.deactivate() }
    }

    /// One turn after a policy change, when activating reliably fronts the window and the menu bar. If Lyra still
    /// isn't active a turn later, it asks once more through its running-application record.
    private func activate() {
        Task { @MainActor in
            NSApp.activate()
            await Task.yield()
            if !NSApp.isActive, !NSRunningApplication.current.activate(options: .activateAllWindows) {
                NSLog("Lyra couldn't bring its window to the front")
            }
        }
    }

    private static func describe(_ windows: [NSWindow]) -> [DockPolicy.Window] {
        windows.map {
            DockPolicy.Window(id: $0.windowNumber, isPanel: $0 is NSPanel, isTitled: $0.styleMask.contains(.titled),
                              isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized)
        }
    }

    /// SwiftUI names a `Window` scene's window after its id ("main", or "main-…").
    private static func isMain(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == MainWindow.id || id.hasPrefix(MainWindow.id + "-")
    }
}

/// Hands SwiftUI's window opener to `DockPresence` from a view that is on screen.
struct MainWindowOpener: ViewModifier {
    let presence: DockPresence
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard presence.openMain == nil else { return }
            presence.openMain = { openWindow(id: MainWindow.id) }
        }
    }
}
