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
        // speakerDatabase is FluidAudio's plain (un-normalised) per-speaker mean, keyed by segment.speakerId.
        let centroids = Diarization.normalisedCentroids(
            database: result.speakerDatabase, segments: result.segments.map { ($0.speakerId, $0.embedding) })
        return Diarization(turns: turns, centroids: centroids)
    }
}
