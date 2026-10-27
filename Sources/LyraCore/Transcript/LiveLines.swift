import Foundation

/// One line of the rough live transcript, labelled by track only: names come after the meeting.
public struct LiveLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let track: TrackKind
    public var text: String
    public var isFinal: Bool

    /// "Me" for the mic, "Them" for the meeting app's audio.
    public var label: String { track == .mic ? "Me" : "Them" }
}

/// The live transcript as it is spoken. Each track has at most one open (non-final) line, which new
/// text replaces until final text closes it; the next text then starts a new line.
public struct LiveLines: Equatable, Sendable {
    public private(set) var lines: [LiveLine] = []

    public init() {}

    public mutating func apply(track: TrackKind, text: String, isFinal: Bool) {
        if let open = lines.lastIndex(where: { $0.track == track && !$0.isFinal }) {
            lines[open].text = text
            lines[open].isFinal = isFinal
        } else {
            lines.append(LiveLine(id: UUID(), track: track, text: text, isFinal: isFinal))
        }
    }
}
