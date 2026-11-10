import Foundation

/// What one look at the call window came to. Only these outcomes are kept, never window titles or pictures.
public enum CallLook: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    /// A picture of the call window was taken.
    case seen
    /// Lyra isn't allowed to see the screen (Screen Recording is off for it).
    case noPermission
    /// The meeting app had no window titled as the call (a browser showing another tab, or no call window open).
    case noCallWindow
    /// The call window was there but not on this desktop (full screen on its own desktop, or minimised), and no
    /// picture could be taken of it.
    case offScreen
    /// The call window was found but taking its picture failed.
    case captureFailed
}

/// Counts a call recording's looks at the call window by outcome, so a call where Lyra never saw the window says
/// why in its note instead of quietly naming no one from the screen. Kept in `callwindow.json`.
public struct CallWatchHealth: Codable, Equatable, Sendable {
    public static let fileName = "callwindow.json"

    public private(set) var counts: [CallLook: Int] = [:]

    public init() {}

    public mutating func record(_ look: CallLook) {
        counts[look, default: 0] += 1
    }

    /// One plain sentence for the note when the window was looked for but never seen; nil when it was seen even
    /// once, or never looked for. No permission, if it happened at all, is the reason (the one Aidan can fix);
    /// otherwise the most common miss is.
    public var warning: String? {
        guard counts[.seen, default: 0] == 0 else { return nil }
        let misses = CallLook.allCases.filter { $0 != .seen && counts[$0, default: 0] > 0 }
        let commonest = misses.max(by: { counts[$0, default: 0] < counts[$1, default: 0] })
        guard let top = misses.contains(.noPermission) ? .noPermission : commonest else { return nil }
        let after = ", so speakers are named by voice and from the conversation only."
        switch top {
        case .seen: return nil
        case .noPermission:
            return "Lyra couldn't see the call window because Screen Recording is off for Lyra" + after
                + " Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .noCallWindow:
            return "Lyra couldn't find the call window (in a browser, the call's tab has to be the one showing)" + after
        case .offScreen:
            return "Lyra couldn't see the call window because it was full screen on another desktop or minimised" + after
        case .captureFailed:
            return "Lyra found the call window but couldn't take a picture of it" + after
        }
    }

    /// No file or an unreadable one: nothing counted.
    public static func load(from folder: URL) -> CallWatchHealth {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return CallWatchHealth() }
        return (try? JSONDecoder().decode(CallWatchHealth.self, from: data)) ?? CallWatchHealth()
    }

    /// Nothing counted (not a call, or never looked yet): nothing written.
    public func save(in folder: URL) throws {
        guard !counts.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
