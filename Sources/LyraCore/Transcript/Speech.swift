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

    /// One unit-length fingerprint per speaker in `segments`: the engine's `database` vector if it has a
    /// non-empty one, else the mean of that speaker's segment embeddings. Skipped when the vector is empty,
    /// all zero or non-finite, or the segment embeddings disagree on dimension.
    public static func normalisedCentroids(database: [String: [Float]]?,
                                           segments: [(speaker: String, embedding: [Float])]) -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for speaker in Set(segments.map(\.speaker)) {
            var v = database?[speaker] ?? []
            if v.isEmpty {
                let embeddings = segments.filter { $0.speaker == speaker }.map(\.embedding)
                guard let first = embeddings.first, embeddings.allSatisfy({ $0.count == first.count }) else { continue }
                v = embeddings.dropFirst().reduce(first) { zip($0, $1).map(+) }  // the mean's direction; scale goes below
            }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }  // also catches NaN, empty and all-zero
            out[speaker] = v.map { $0 / norm }
        }
        return out
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
