import Foundation

public struct MatchPolicy: Sendable {
    public var minSimilarity: Double = 0.60
    public var minMargin: Double = 0.10
    public init(minSimilarity: Double = 0.60, minMargin: Double = 0.10) {
        self.minSimilarity = minSimilarity; self.minMargin = minMargin
    }
}

public struct VoiceMatch: Sendable, Equatable {
    public let personID: UUID
    public let similarity: Double
}

public enum VoiceMatcher {
    /// The person whose prototype is closest to `centroid`, or nil when unsure.
    /// With a single candidate the runner-up counts as -1 (the lowest cosine), so a lone known
    /// person is judged on `minSimilarity` alone; the margin check can't reject them.
    public static func match(_ centroid: [Float], people: [Person], policy: MatchPolicy = .init()) -> VoiceMatch? {
        guard let c = unit(centroid) else { return nil }
        var best: (id: UUID, sim: Double)?
        var second = -1.0
        for p in people {
            guard let proto = unit(p.prototype), proto.count == c.count else { continue }
            let sim = zip(c, proto).reduce(0.0) { $0 + Double($1.0 * $1.1) }
            if let b = best, sim <= b.sim { second = max(second, sim) }
            else { if let b = best { second = max(second, b.sim) }; best = (p.id, sim) }
        }
        guard let b = best, b.sim >= policy.minSimilarity, b.sim - second >= policy.minMargin else { return nil }
        return VoiceMatch(personID: b.id, similarity: b.sim)
    }

    private static func unit(_ v: [Float]) -> [Float]? {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard !v.isEmpty, norm > 0, norm.isFinite else { return nil }
        return v.map { $0 / norm }
    }
}
