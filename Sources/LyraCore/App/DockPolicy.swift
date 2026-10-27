import Foundation

/// When Lyra is a Dock app and what the Dock icon does, decided over plain descriptions of its windows so it can
/// be tested without AppKit. A Lyra window is a titled, non-panel window that is shown or minimised: home, meeting,
/// enrolment. The Allow prompt (a panel), alerts and the menu bar item never count.
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

    private static func lyraWindows(_ windows: [Window], closing: Set<Int>) -> [Window] {
        windows.filter { !closing.contains($0.id) && !$0.isPanel && $0.isTitled && ($0.isVisible || $0.isMiniaturized) }
    }
}
