import Foundation

/// Finds the transcript lines closest to a stretch of Aidan's notes, by words they share.
public enum TranscriptSearch {
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "is", "are", "was", "to", "of", "in", "on", "for", "it", "that", "this", "with", "we", "i", "you",
    ]

    /// Indices of the best-matching lines: most shared non-stopwords first, ties by time. Lines sharing none are left out.
    public static func lines(matching selection: String, in lines: [TranscriptLine], limit: Int = 3) -> [Int] {
        let wanted = words(in: selection)
        guard !wanted.isEmpty, limit > 0 else { return [] }
        let scored: [(index: Int, score: Int)] = lines.indices.compactMap { index in
            let score = words(in: lines[index].text).intersection(wanted).count
            return score > 0 ? (index, score) : nil
        }
        let ranked = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if lines[a.index].start != lines[b.index].start { return lines[a.index].start < lines[b.index].start }
            return a.index < b.index
        }
        return ranked.prefix(limit).map(\.index)
    }

    private static func words(in text: String) -> Set<String> {
        let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(tokens.filter { !$0.isEmpty && !stopwords.contains($0) })
    }
}
