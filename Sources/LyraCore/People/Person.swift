import Foundation

/// A known speaker: a name plus the voice fingerprints (unit vectors) learned for them.
public struct Person: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var isOwner: Bool
    public var samples: [[Float]]
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, isOwner: Bool = false, samples: [[Float]] = [], updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.isOwner = isOwner; self.samples = samples; self.updatedAt = updatedAt
    }

    /// L2-normalised mean of `samples`. Empty when there are no samples (or they cancel out), so such a person never matches.
    public var prototype: [Float] {
        guard let first = samples.first else { return [] }
        let sum = samples.dropFirst().reduce(first) { acc, s in s.count == acc.count ? zip(acc, s).map(+) : acc }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return [] }
        return sum.map { $0 / norm }
    }
}
