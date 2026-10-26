import Foundation

/// A span where one speaker talks. `speaker` is the engine's raw cluster id.
public struct SpeakerTurn: Sendable {
    public let speaker: String
    public let start: Double
    public let end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker; self.start = start; self.end = end
    }
}

/// Speaker turns plus one voice fingerprint per cluster.
public struct Diarization: Sendable {
    public let turns: [SpeakerTurn]
    /// Raw cluster id (as in `SpeakerTurn.speaker`) → L2-normalised embedding.
    public let centroids: [String: [Float]]

    public init(turns: [SpeakerTurn], centroids: [String: [Float]]) {
        self.turns = turns; self.centroids = centroids
    }
}

/// Splits 16 kHz mono audio into speaker turns.
public protocol SpeakerDiarizing: Sendable {
    func diarize(samples: [Float]) async throws -> Diarization
}

/// One recognised word. Times are seconds from the start of the samples passed in.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

/// Turns 16 kHz mono audio into timed words.
public protocol SpeechTranscribing: Sendable {
    func transcribe(samples: [Float]) async throws -> [TimedWord]
}
