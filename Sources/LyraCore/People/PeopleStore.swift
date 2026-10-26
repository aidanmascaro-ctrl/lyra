import Foundation

public enum PeopleStoreError: Error, Equatable {
    case badSample, emptyName, dimensionMismatch, unknownPerson, nameTaken
}

/// Local voice-print database. Biometric data: lives only under Application Support, mode 0600.
public final class PeopleStore: @unchecked Sendable {  // all state is behind `lock`
    public static let maxSamples = 20
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyra/people.json")
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var people: [Person]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.people = Self.load(fileURL)
    }

    public func all() -> [Person] { lock.withLock { people } }

    public func person(named name: String) -> Person? {
        let key = Self.key(name)
        return lock.withLock { people.first { Self.key($0.name) == key } }
    }

    @discardableResult
    public func learn(name: String, sample: [Float], isOwner: Bool = false) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleStoreError.emptyName }
        guard !sample.isEmpty, sample.allSatisfy(\.isFinite) else { throw PeopleStoreError.badSample }
        return try lock.withLock {
            var next = people
            let key = Self.key(trimmed)
            let now = Date()
            let result: Person
            if let i = next.firstIndex(where: { Self.key($0.name) == key }) {
                if let dim = next[i].samples.first?.count, dim != sample.count { throw PeopleStoreError.dimensionMismatch }
                next[i].samples = Array((next[i].samples + [sample]).suffix(Self.maxSamples))
                next[i].isOwner = next[i].isOwner || isOwner
                next[i].updatedAt = now
                result = next[i]
            } else {
                result = Person(name: trimmed, isOwner: isOwner, samples: [sample], updatedAt: now)
                next.append(result)
            }
            try save(next)
            people = next
            return result
        }
    }

    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleStoreError.emptyName }
        try lock.withLock {
            guard let i = people.firstIndex(where: { $0.id == id }) else { throw PeopleStoreError.unknownPerson }
            let key = Self.key(trimmed)
            if people.contains(where: { $0.id != id && Self.key($0.name) == key }) { throw PeopleStoreError.nameTaken }
            var next = people
            next[i].name = trimmed
            next[i].updatedAt = Date()
            try save(next)
            people = next
        }
    }

    // MARK: -

    /// Trimmed, internal whitespace collapsed, case-folded.
    private static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private func save(_ list: [Person]) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try JSONEncoder().encode(list).write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func load(_ url: URL) -> [Person] {
        guard let data = try? Data(contentsOf: url) else { return [] }  // missing file: start empty
        if let list = try? JSONDecoder().decode([Person].self, from: data) { return list }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(f.string(from: Date()))")
        try? FileManager.default.moveItem(at: url, to: aside)
        return []
    }
}
