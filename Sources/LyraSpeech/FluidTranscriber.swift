import FluidAudio
import Foundation
import LyraCore

/// On-device English ASR via FluidAudio's Parakeet TDT. Models download on first use.
/// Audio longer than the model's 15 s window is chunked inside FluidAudio (`ChunkProcessor`),
/// which returns token times already offset to the start of the input.
public actor FluidTranscriber: SpeechTranscribing {
    // Parakeet Ultra: FluidAudio's recommended v3-family model, more accurate on English
    // than v3 (LibriSpeech test-clean 2.13 % vs 2.27 %) at the same speed. v2 (English-only) scores worse (3.8 % vs 2.6 %).
    private let version: AsrModelVersion
    private var manager: AsrManager?

    public init(version: AsrModelVersion = .ultra) {
        self.version = version
    }

    public func transcribe(samples: [Float]) async throws -> [TimedWord] {
        // FluidAudio rejects < 0.3 s outright; a track that short holds no words.
        guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate) else { return [] }
        let asr: AsrManager
        if let manager {
            asr = manager
        } else {
            asr = AsrManager(config: .default)
            try await asr.loadModels(AsrModels.downloadAndLoad(version: version))
            manager = asr
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state, language: .english)
        // Tokens are SentencePiece sub-words; FluidAudio merges them on the "▁"/leading-space marker.
        return buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }
}
