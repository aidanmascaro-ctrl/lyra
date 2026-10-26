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

/// Splits 16 kHz mono audio into speaker turns.
public protocol SpeakerDiarizing: Sendable {
    func diarize(samples: [Float]) async throws -> [SpeakerTurn]
}

/// Turns 16 kHz mono audio into text.
public protocol SpeechTranscribing: Sendable {
    func transcribe(samples: [Float]) async throws -> String
}
