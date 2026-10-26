import FluidAudio
import Foundation
import LyraCore

/// On-device diarization via FluidAudio's offline (pyannote + VBx) pipeline.
/// Models download on first use, then load from FluidAudio's on-disk cache.
public struct FluidDiarizer: SpeakerDiarizing {
    private let config: OfflineDiarizerConfig

    public init(config: OfflineDiarizerConfig = .default) {
        self.config = config
    }

    public func diarize(samples: [Float]) async throws -> Diarization {
        // ponytail: fresh manager per call (it isn't Sendable); costs a cached model load per track.
        // Keep one alive behind a lock if per-track load time ever matters.
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            return Diarization(turns: [], centroids: [:])  // silence (e.g. no Audio Capture permission) is empty, not a failure
        }
        let turns = result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        return Diarization(turns: turns, centroids: Self.centroids(result))
    }

    /// One unit-length fingerprint per speaker: FluidAudio's `speakerDatabase` (a plain, un-normalised mean,
    /// keyed by `segment.speakerId`), else the mean of that speaker's segment embeddings. Empty or all-zero is skipped.
    static func centroids(_ result: DiarizationResult) -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for speaker in Set(result.segments.map(\.speakerId)) {
            var v = result.speakerDatabase?[speaker] ?? []
            if v.isEmpty {
                let embeddings = result.segments.filter { $0.speakerId == speaker && !$0.embedding.isEmpty }.map(\.embedding)
                guard let first = embeddings.first, embeddings.allSatisfy({ $0.count == first.count }) else { continue }
                v = embeddings.dropFirst().reduce(first) { zip($0, $1).map(+) }
            }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            out[speaker] = v.map { $0 / norm }
        }
        return out
    }
}
