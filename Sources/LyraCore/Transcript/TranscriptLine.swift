import Foundation

/// One speaker-attributed line of a meeting transcript. Times are seconds from the track start.
public struct TranscriptLine: Codable, Equatable, Sendable {
    public var speakerLabel: String
    public let track: TrackKind
    public let start: Double
    public let end: Double
    public let text: String

    public init(speakerLabel: String, track: TrackKind, start: Double, end: Double, text: String) {
        self.speakerLabel = speakerLabel; self.track = track
        self.start = start; self.end = end; self.text = text
    }
}
