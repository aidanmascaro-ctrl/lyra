import Foundation

/// How a line's person was named: matched from a known voice, read off the call's lit tile, or set by Aidan by hand.
public enum NameSource: String, Codable, Sendable { case knownVoice, onScreen, setByAidan }

/// One speaker-attributed line of a meeting transcript. Times are seconds on the shared meeting timeline
/// (the track's start offset applied), not seconds into that track's own audio file.
/// The people fields are optional so Phase 1 transcripts still decode.
public struct TranscriptLine: Codable, Equatable, Sendable {
    public var speakerLabel: String
    /// The raw `"<track>:<cluster>"` id, kept after `speakerLabel` becomes "Speaker N".
    public var speakerID: String?
    public var personID: UUID?
    public var nameSource: NameSource?
    public var confidence: Double?
    public let track: TrackKind
    public var start: Double
    public var end: Double
    public let text: String

    public init(speakerLabel: String, speakerID: String? = nil, track: TrackKind, start: Double, end: Double, text: String) {
        self.speakerLabel = speakerLabel; self.speakerID = speakerID; self.track = track
        self.start = start; self.end = end; self.text = text
    }
}
