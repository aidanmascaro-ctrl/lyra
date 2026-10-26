import Foundation

/// One diarization cluster from one track of one meeting, with its voice fingerprint. Saved as `speakers.json`.
public struct SpeakerCluster: Codable, Sendable, Equatable {
    /// `"<track>:<raw cluster id>"`, the same string as `TranscriptLine.speakerID`.
    public let id: String
    public let track: TrackKind
    /// Unit-length (L2-normalised) speaker embedding.
    public let centroid: [Float]
    /// Total length of this cluster's turns, in seconds.
    public let speechSeconds: Double

    public init(id: String, track: TrackKind, centroid: [Float], speechSeconds: Double) {
        self.id = id; self.track = track; self.centroid = centroid; self.speechSeconds = speechSeconds
    }
}
