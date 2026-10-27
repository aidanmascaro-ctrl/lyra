import AppKit
import SwiftUI

/// Lyra is a Dock app (Dock icon, ⌘-Tab, app menu) while any of its windows is open, and menu-bar-only once the
/// last one closes. Info.plist's `LSUIElement` makes it start menu-bar-only. Recording, detection and processing
/// don't depend on any of this.
@MainActor
final class DockPresence: NSObject {
    /// Opens and fronts the home window. Set by `HomeOpener`, since only a SwiftUI view has `openWindow`.
    var openHome: (() -> Void)?

    func start() {
        let center = NotificationCenter.default
        // A window coming on screen (occlusion changes then) or forward makes Lyra a Dock app; closing may end it.
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowChanged() { update(closing: nil) }

    @objc private func windowWillClose(_ notification: Notification) { update(closing: notification.object as? NSWindow) }

    private func update(closing: NSWindow?) {
        let open = NSApp.windows.contains { $0 !== closing && Self.isLyraWindow($0) }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // A window just appeared because Aidan asked for it: bring it forward. The last one closed: give the
        // keyboard back to whatever he was using.
        if open { NSApp.activate() } else { NSApp.deactivate() }
    }

    /// Home, meeting and enrolment: titled windows, shown or in the Dock. Not the Allow prompt (a panel), alerts
    /// or the menu bar item.
    private static func isLyraWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
    }
}

/// Hands the home window's opener to `DockPresence`, from a view that is always there (the menu bar label).
struct HomeOpener: ViewModifier {
    let presence: DockPresence
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            presence.openHome = {
                openWindow(id: "home")
                NSApp.activate()
            }
        }
    }
}
