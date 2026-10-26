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

    public func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        // ponytail: fresh manager per call (it isn't Sendable); costs a cached model load per track.
        // Keep one alive behind a lock if per-track load time ever matters.
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        return try await manager.process(audio: samples).segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }
}
