import Foundation

public enum SpeakerNamer {
    /// Puts known names on merged lines (run after the echo filter) and gives everyone else the final "Speaker N".
    /// A cluster whose voice matches a person gets their name, `personID`, `.knownVoice` and the similarity as
    /// `confidence`. Unknowns, including lines with no cluster at all, are numbered by first appearance,
    /// skipping named people. Adjacent lines of one person on one track, at most `TrackTranscriber.maxPause`
    /// apart, become one line (a voice split into two clusters reads as one speaker); the first `speakerID` stays.
    /// Never writes to the people store.
    public static func name(lines: [TranscriptLine], clusters: [SpeakerCluster], people: [Person], policy: MatchPolicy) -> [TranscriptLine] {
        var known: [String: (person: Person, similarity: Double)] = [:]
        for c in clusters {
            if let m = VoiceMatcher.match(c.centroid, people: people, policy: policy),
               let p = people.first(where: { $0.id == m.personID }) {
                known[c.id] = (p, m.similarity)
            }
        }
        var numbers: [String: Int] = [:]
        var out: [TranscriptLine] = []
        for line in lines {
            let raw = line.speakerID ?? line.speakerLabel
            var l = line
            guard let k = known[raw] else {
                let n = numbers[raw] ?? numbers.count + 1
                numbers[raw] = n
                l.speakerLabel = "Speaker \(n)"
                out.append(l)
                continue
            }
            if let last = out.last, last.personID == k.person.id, last.track == line.track,
               line.start - last.end <= TrackTranscriber.maxPause {
                var joined = TranscriptLine(speakerLabel: last.speakerLabel, speakerID: last.speakerID, track: last.track,
                                            start: last.start, end: max(last.end, line.end), text: last.text + " " + line.text)
                joined.personID = last.personID
                joined.nameSource = last.nameSource
                joined.confidence = min(last.confidence ?? 1, k.similarity)  // a join is only as sure as its weaker half
                out[out.count - 1] = joined
                continue
            }
            l.speakerLabel = k.person.name
            l.personID = k.person.id
            l.nameSource = .knownVoice
            l.confidence = k.similarity
            out.append(l)
        }
        return out
    }
}
