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

    func makeNSView(context: Context) -> NSView { StripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class StripView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch Action(setting: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
            case .zoom: window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        }
    }
}
