import Foundation

/// Transcribes one track once, diarizes it, then gives each word to a speaker.
/// Nothing the recogniser hears is dropped: a word outside every turn goes to the nearest one.
public struct TrackTranscriber: Sendable {
    static let maxPause = 1.5  // seconds; a longer gap between words starts a new line

    private let diarizer: SpeakerDiarizing
    private let transcriber: SpeechTranscribing

    public init(diarizer: SpeakerDiarizing, transcriber: SpeechTranscribing) {
        self.diarizer = diarizer
        self.transcriber = transcriber
    }

    /// `sampleRate` is kept for callers; word times come back from the transcriber in seconds.
    /// Clusters are returned only for raw ids that have a centroid and own at least one line.
    public func run(samples: [Float], track: TrackKind, sampleRate: Double = 16_000) async throws
        -> (lines: [TranscriptLine], clusters: [SpeakerCluster]) {
        let words = try await transcriber.transcribe(samples: samples)
        guard !words.isEmpty else { return ([], []) }  // a silent track: nothing to attribute, so don't diarize
        let diarization = try await diarizer.diarize(samples: samples)
        let turns = diarization.turns

        var lines: [TranscriptLine] = []
        var clusters: [SpeakerCluster] = []
        for word in words {
            let raw = Self.speaker(of: word, in: turns) ?? "0"
            let label = "\(track.rawValue):\(raw)"
            if let last = lines.last, last.speakerLabel == label, word.start - last.end <= Self.maxPause {
                lines[lines.count - 1] = TranscriptLine(
                    speakerLabel: label, speakerID: label, track: track, start: last.start, end: word.end,
                    text: last.text + " " + word.text)
            } else {
                lines.append(TranscriptLine(speakerLabel: label, speakerID: label, track: track, start: word.start, end: word.end, text: word.text))
            }
            if let centroid = diarization.centroids[raw], !clusters.contains(where: { $0.id == label }) {
                let seconds = turns.filter { $0.speaker == raw }.reduce(0) { $0 + $1.end - $1.start }
                clusters.append(SpeakerCluster(id: label, track: track, centroid: centroid, speechSeconds: seconds))
            }
        }
        return (lines, clusters)
    }

    /// The turn overlapping the word most; if none overlaps, the nearest turn in time.
    static func speaker(of word: TimedWord, in turns: [SpeakerTurn]) -> String? {
        func overlap(_ t: SpeakerTurn) -> Double { min(word.end, t.end) - max(word.start, t.start) }
        func distance(_ t: SpeakerTurn) -> Double { max(t.start - word.end, word.start - t.end, 0) }
        if let best = turns.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best.speaker }
        return turns.min(by: { distance($0) < distance($1) })?.speaker
    }
}
