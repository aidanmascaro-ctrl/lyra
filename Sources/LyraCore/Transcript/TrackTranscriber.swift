import Foundation

/// Diarizes one track, then transcribes each speaker turn on its own.
public struct TrackTranscriber: Sendable {
    static let minTurn = 0.3   // seconds; shorter turns are noise
    static let mergeGap = 0.5  // seconds; same-speaker turns closer than this become one

    private let diarizer: SpeakerDiarizing
    private let transcriber: SpeechTranscribing

    public init(diarizer: SpeakerDiarizing, transcriber: SpeechTranscribing) {
        self.diarizer = diarizer
        self.transcriber = transcriber
    }

    public func run(samples: [Float], track: TrackKind, sampleRate: Double = 16_000) async throws -> [TranscriptLine] {
        let turns = try await diarizer.diarize(samples: samples)
            .filter { $0.end - $0.start >= Self.minTurn }
            .sorted { $0.start < $1.start }

        var merged: [SpeakerTurn] = []
        for turn in turns {
            if let last = merged.last, last.speaker == turn.speaker, turn.start - last.end < Self.mergeGap {
                merged[merged.count - 1] = SpeakerTurn(speaker: last.speaker, start: last.start, end: max(last.end, turn.end))
            } else {
                merged.append(turn)
            }
        }

        var lines: [TranscriptLine] = []
        for turn in merged {
            let lo = max(0, min(samples.count, Int(turn.start * sampleRate)))
            let hi = max(lo, min(samples.count, Int(turn.end * sampleRate)))
            let text = try await transcriber.transcribe(samples: Array(samples[lo..<hi]))
            lines.append(TranscriptLine(
                speakerLabel: "\(track.rawValue):\(turn.speaker)", track: track,
                start: turn.start, end: turn.end,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return lines
    }
}
