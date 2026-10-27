import AppKit
import LyraCore
import SwiftUI

/// Lyra is a Dock app (Dock icon, ⌘-Tab, app menu) while any of its windows is open, and menu-bar-only once the
/// last one closes; `DockPolicy` decides. Info.plist's `LSUIElement` makes it start menu-bar-only. Recording,
/// detection and processing don't depend on any of this.
@MainActor
final class DockPresence: NSObject {
    /// Opens and fronts the home window through SwiftUI's `openWindow`. Set by `HomeOpener` from the menu bar label
    /// and from home itself (shown at every launch), so it is there whichever appears first.
    var openHome: (() -> Void)?
    /// Windows told to close that may still report visible; dropped a turn later, once they are really gone.
    private var closing: Set<Int> = []

    func start() {
        let center = NotificationCenter.default
        // A window coming on screen (occlusion changes then) or forward makes Lyra a Dock app; closing may end it.
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    /// The Dock icon clicked, or Lyra opened again: minimised windows come back, open ones come forward, and with
    /// none open, home opens.
    func reopen() {
        switch DockPolicy.reopen(Self.describe(NSApp.windows), closing: closing) {
        case .openHome:
            showHome()
        case .front(let restore):
            for window in NSApp.windows where restore.contains(window.windowNumber) { window.deminiaturize(nil) }
            NSApp.windows.first { $0.windowNumber == restore.first }?.makeKeyAndOrderFront(nil)
            activate()
        }
    }

    /// Home through SwiftUI when it has handed over `openWindow`; otherwise a home window AppKit still holds.
    private func showHome() {
        if let openHome { openHome() } else { NSApp.windows.first(where: Self.isHome)?.makeKeyAndOrderFront(nil) }
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
        update()
        // Checked again once the close has finished, so a late occlusion or key change can't leave a Dock icon
        // with no window.
        Task { @MainActor [weak self] in
            self?.closing.remove(number)
            self?.update()
        }
    }

    private func update() {
        let policy: NSApplication.ActivationPolicy = DockPolicy.showsInDock(Self.describe(NSApp.windows), closing: closing)
            ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
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

    /// SwiftUI names a `Window` scene's window after its id ("home", or "home-…").
    private static func isHome(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == "home" || id.hasPrefix("home-")
    }
}

/// Hands SwiftUI's window opener to `DockPresence` from a view that is on screen.
struct HomeOpener: ViewModifier {
    let presence: DockPresence
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard presence.openHome == nil else { return }
            presence.openHome = { openWindow(id: "home") }
        }
    }
}
