import FluidAudio
import Foundation
import LyraCore

/// On-device English ASR via FluidAudio's Parakeet TDT. Models download on first use.
public actor FluidTranscriber: SpeechTranscribing {
    // Parakeet Ultra: FluidAudio's recommended v3-family model, more accurate on English
    // than v3 (LibriSpeech test-clean 2.13 % vs 2.27 %) at the same speed. v2 (English-only) scores worse (3.8 % vs 2.6 %).
    private let version: AsrModelVersion
    private var manager: AsrManager?

    public init(version: AsrModelVersion = .ultra) {
        self.version = version
    }

    public func transcribe(samples: [Float]) async throws -> String {
        let asr: AsrManager
        if let manager {
            asr = manager
        } else {
            asr = AsrManager(config: .default)
            try await asr.loadModels(AsrModels.downloadAndLoad(version: version))
            manager = asr
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state).text
    }
}
