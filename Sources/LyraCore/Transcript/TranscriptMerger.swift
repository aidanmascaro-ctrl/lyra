import Foundation

public enum TranscriptMerger {
    /// Merges both tracks, drops mic lines that are an echo of the call, and relabels speakers.
    public static func merge(meeting: [TranscriptLine], mic: [TranscriptLine]) -> [TranscriptLine] {
        let meetingWords = meeting.map { words($0.text) }
        let keptMic = mic.filter { m in
            let mw = words(m.text)
            guard mw.count >= 3 else { return true }
            let union = meeting.indices.filter { m.start <= meeting[$0].end + 2 && m.end >= meeting[$0].start - 2 }
                .reduce(into: Set<String>()) { $0.formUnion(meetingWords[$1]) }
            return Double(mw.intersection(union).count) / Double(mw.count) < 0.6
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

    private static func words(_ text: String) -> Set<String> {
        let cleaned = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) ? Character($0) : " " }
        return Set(String(cleaned).split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
