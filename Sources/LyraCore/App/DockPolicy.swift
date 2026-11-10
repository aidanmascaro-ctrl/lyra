import Foundation

/// When Lyra is a Dock app and what the Dock icon does, decided over plain descriptions of its windows so it can
/// be tested without AppKit. A Lyra window is a titled, non-panel window that is shown or minimised: the main window
/// (home or a meeting) and enrolment. The Allow prompt (a panel), alerts and the menu bar item never count.
public enum DockPolicy {
    public struct Window: Equatable, Sendable {
        public let id: Int
        public let isPanel: Bool
        public let isTitled: Bool
        public let isVisible: Bool
        public let isMiniaturized: Bool

        public init(id: Int, isPanel: Bool, isTitled: Bool, isVisible: Bool, isMiniaturized: Bool) {
            self.id = id
            self.isPanel = isPanel
            self.isTitled = isTitled
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
        }
    }

    public enum Reopen: Equatable, Sendable {
        /// No Lyra window: open home.
        case openHome
        /// Bring Lyra's windows forward, un-minimising these first.
        case front(restore: [Int])
    }

    /// True while any Lyra window is open. `closing` are windows being closed that may still report visible.
    public static func showsInDock(_ windows: [Window], closing: Set<Int>) -> Bool {
        !lyraWindows(windows, closing: closing).isEmpty
    }

    /// The Dock icon clicked or Lyra opened again.
    public static func reopen(_ windows: [Window], closing: Set<Int>) -> Reopen {
        let open = lyraWindows(windows, closing: closing)
        guard !open.isEmpty else { return .openHome }
        return .front(restore: open.filter { $0.isMiniaturized }.map(\.id))
    }

    public enum MenuBarClick: Equatable, Sendable {
        /// Lyra is already in front: hide it, keeping whatever page it is on.
        case hide
        /// Bring Lyra forward: unhide it, then as `reopen` (restore a minimised window, or open home).
        case show
    }

    /// The menu-bar icon left-clicked: a toggle. Hide when Lyra is the app in front with one of its windows showing;
    /// show it otherwise (another app in front, Lyra hidden, or only minimised or no windows).
    public static func menuBarClick(_ windows: [Window], closing: Set<Int>, isActive: Bool, isHidden: Bool) -> MenuBarClick {
        let showing = lyraWindows(windows, closing: closing).contains { $0.isVisible && !$0.isMiniaturized }
        return isActive && !isHidden && showing ? .hide : .show
    }

    /// A rectangle on screen in plain numbers. LyraCore stays free of CoreGraphics types: CGRect here crashed the
    /// release compiler's cross-module optimiser, which can't resolve it from a module that doesn't import CoreGraphics.
    public struct Frame: Equatable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    /// Where a window `width` × `height` goes on a screen's usable area (`visible`): centred, and shrunk to fit if it
    /// is bigger. Used when a menu-bar click opens Lyra on a different display from the one its window is on.
    public static func place(width: Double, height: Double, on visible: Frame) -> Frame {
        let w = min(width, visible.width)
        let h = min(height, visible.height)
        return Frame(x: visible.x + (visible.width - w) / 2, y: visible.y + (visible.height - h) / 2, width: w, height: h)
    }

    private static func lyraWindows(_ windows: [Window], closing: Set<Int>) -> [Window] {
        windows.filter { !closing.contains($0.id) && !$0.isPanel && $0.isTitled && ($0.isVisible || $0.isMiniaturized) }
    }
}
