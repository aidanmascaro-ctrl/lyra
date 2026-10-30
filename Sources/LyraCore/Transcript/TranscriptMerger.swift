import Foundation

public enum TranscriptMerger {
    /// Echo reaches the mic at the same moment the call plays it, so only near-simultaneous lines can be echo.
    static let echoPad = 0.5

    /// Merges both tracks, drops mic lines that are an echo of the call, and relabels speakers (the raw id stays in `speakerID`).
    /// A mic line (3+ words) is echo when ≥ 60% of its word pairs appear in call lines overlapping it in time.
    /// Word pairs, not single words: a reply reuses the question's stopwords, but not its phrasing.
    public static func merge(meeting: [TranscriptLine], mic: [TranscriptLine]) -> [TranscriptLine] {
        let meetingPairs = meeting.map { Set(bigrams(words($0.text))) }
        let keptMic = mic.filter { m in
            let mw = words(m.text)
            guard mw.count >= 3 else { return true }
            let heard = meeting.indices.filter { m.start <= meeting[$0].end + echoPad && m.end >= meeting[$0].start - echoPad }
                .reduce(into: Set<String>()) { $0.formUnion(meetingPairs[$1]) }
            let pairs = bigrams(mw)
            return Double(pairs.filter(heard.contains).count) / Double(pairs.count) < 0.6
        }
        // Stable sort is not guaranteed by sort(by:), so break ties explicitly: meeting before mic.
        let sorted = (meeting + keptMic).enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.track != b.element.track { return a.element.track == .meeting }
            return a.offset < b.offset
        }.map(\.element)

        var numbers: [String: Int] = [:]
        return sorted.map { line in
            var out = line
            out.speakerID = line.speakerID ?? line.speakerLabel  // keep the raw id through the relabel
            let n = numbers[line.speakerLabel] ?? numbers.count + 1
            numbers[line.speakerLabel] = n
            out.speakerLabel = "Speaker \(n)"
            return out
        }
    }

    /// A mic cluster this close (cosine) to any call cluster is the call leaking into the mic.
    /// Measured 2026-10-27 (docs/notes/phase2-findings.md): a speaker leak scored 0.852 against the call's
    /// voice; different voices scored at most 0.243; the same voice across meetings 0.858-0.866.
    /// 2026-10-30: a Meet call leaking through the speakers scored only 0.678 and got through at 0.75, showing up
    /// as a third speaker. 0.5 sits between that leak and the highest different-voice score (0.245).
    public static let voiceEchoSimilarity = 0.5

    /// Second echo pass, by voice instead of words: catches leaked call audio the text filter missed because
    /// the mic heard it differently. Drops the leaking mic cluster and all its lines. Only a mic cluster that
    /// `VoiceMatcher` names as the owner is kept (Aidan's own voice is never echo); any other known person on
    /// the mic who sounds like the call is the call leaking, so it goes. Centroids are unit-normalised here.
    public static func dropVoiceEcho(lines: [TranscriptLine], clusters: [SpeakerCluster], people: [Person], policy: MatchPolicy)
        -> (lines: [TranscriptLine], clusters: [SpeakerCluster]) {
        let call = clusters.filter { $0.track == .meeting }.compactMap { VoiceMatcher.unit($0.centroid) }
        let echo = Set(clusters.filter { c in
            guard c.track == .mic, let v = VoiceMatcher.unit(c.centroid),
                  call.contains(where: { $0.count == v.count && zip($0, v).reduce(0.0) { $0 + Double($1.0 * $1.1) } >= voiceEchoSimilarity })
            else { return false }
            let match = VoiceMatcher.match(c.centroid, people: people, policy: policy)
            return !(people.first { $0.id == match?.personID }?.isOwner ?? false)
        }.map(\.id))
        return (lines.filter { !echo.contains($0.speakerID ?? "") }, clusters.filter { !echo.contains($0.id) })
    }

    private static func words(_ text: String) -> [String] {
        let cleaned = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) ? Character($0) : " " }
        return String(cleaned).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func bigrams(_ words: [String]) -> [String] {
        zip(words, words.dropFirst()).map { "\($0) \($1)" }
    }
}
