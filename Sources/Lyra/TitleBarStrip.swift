import AppKit
import SwiftUI

/// The empty band across the top of the window. The SwiftUI page covers the hidden title bar, so it never sees the
/// double-click; this strip catches it and does what System Settings › Desktop & Dock says, and still drags the window.
struct TitleBarStrip: NSViewRepresentable {
    enum Action: Equatable {
        case zoom, minimize, none

        /// `AppleActionOnDoubleClick`: unset (the Mac default), "Maximize" (Zoom) or "Fill" zoom.
        init(setting: String?) {
            switch setting {
            case "Minimize": self = .minimize
            case "None": self = .none
            default: self = .zoom
            }
        }
    }

    /// How close to the screen's edges counts as already filling it.
    private static let fillTolerance: CGFloat = 4
    /// A window found filling the screen with no earlier size to go back to shrinks to this share of the screen.
    private static let fallbackShare: CGFloat = 0.75

    /// One double-click: fill `screen` and remember `current`, or go back to the remembered size if the window is
    /// still filling the screen. AppKit's own zoom doesn't reliably toggle back in a SwiftUI window, so Lyra keeps
    /// the old size itself.
    static func zoomStep(current: NSRect, screen: NSRect, saved: NSRect?) -> (frame: NSRect, saved: NSRect?) {
        let filling = abs(current.minX - screen.minX) <= fillTolerance && abs(current.minY - screen.minY) <= fillTolerance
            && abs(current.maxX - screen.maxX) <= fillTolerance && abs(current.maxY - screen.maxY) <= fillTolerance
        guard filling else { return (screen, current) }
        if let saved { return (saved, nil) }
        let smaller = screen.insetBy(dx: screen.width * (1 - fallbackShare) / 2, dy: screen.height * (1 - fallbackShare) / 2)
        return (smaller, nil)
    }

    func makeNSView(context: Context) -> NSView { StripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class StripView: NSView {
        private var savedFrame: NSRect?

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch Action(setting: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
            case .zoom: toggleFill(window)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        }

        private func toggleFill(_ window: NSWindow) {
            guard let screen = window.screen?.visibleFrame else { return }
            let step = TitleBarStrip.zoomStep(current: window.frame, screen: screen, saved: savedFrame)
            savedFrame = step.saved
            window.setFrame(step.frame, display: true, animate: true)
        }
    }
}
