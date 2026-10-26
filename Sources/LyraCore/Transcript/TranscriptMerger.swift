import Foundation

public enum TranscriptMerger {
    /// Echo reaches the mic at the same moment the call plays it, so only near-simultaneous lines can be echo.
    static let echoPad = 0.5

    /// Merges both tracks, drops mic lines that are an echo of the call, and relabels speakers.
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
            let n = numbers[line.speakerLabel] ?? numbers.count + 1
            numbers[line.speakerLabel] = n
            out.speakerLabel = "Speaker \(n)"
            return out
        }
    }

    private static func words(_ text: String) -> [String] {
        let cleaned = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) ? Character($0) : " " }
        return String(cleaned).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func bigrams(_ words: [String]) -> [String] {
        zip(words, words.dropFirst()).map { "\($0) \($1)" }
    }
}
