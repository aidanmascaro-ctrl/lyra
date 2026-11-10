import AppKit
import CoreGraphics
import Foundation

/// Lyra's Screen Recording permission: without it the call window can't be seen (no names off the lit tiles, no
/// screen text, no slides). Lyra shows the system prompt once only; after that this opens the settings page.
enum ScreenAccess {
    private static let settingsPage = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    static var isGranted: Bool {
        #if DEBUG
        // `LYRA_DEBUG_NO_SCREEN=1`: act as if it's off, to look at the bar (a debug run borrows Terminal's permission).
        if ProcessInfo.processInfo.environment["LYRA_DEBUG_NO_SCREEN"] == "1" { return false }
        #endif
        return CGPreflightScreenCaptureAccess()
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    static func openSettings() {
        guard let settingsPage else { return }
        NSWorkspace.shared.open(settingsPage)
    }
}
