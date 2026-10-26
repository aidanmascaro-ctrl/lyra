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
    /// Set when an existing file could not be read or set aside; writes then refuse so its bytes are never replaced.
    private let loadFailure: Error?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        (self.people, self.loadFailure) = Self.load(fileURL)
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
        if let loadFailure { throw loadFailure }
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
        if let loadFailure { throw loadFailure }
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
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)  // also tightens a pre-existing directory
        // Temp file is born 0600 in the same directory, then renamed over the target: no window with looser perms.
        let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(list), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if Darwin.rename(tmp.path, fileURL.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Missing file: empty. Unreadable file, or corrupt file that can't be set aside: empty plus a failure that blocks writes.
    private static func load(_ url: URL) -> ([Person], Error?) {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile { return ([], nil) }
        catch { return ([], error) }
        if let list = try? JSONDecoder().decode([Person].self, from: data) { return (list, nil) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.lastPathComponent).corrupt-\(f.string(from: Date()))"
        let dir = url.deletingLastPathComponent()
        var aside = dir.appendingPathComponent(base)
        var n = 1
        while FileManager.default.fileExists(atPath: aside.path) { aside = dir.appendingPathComponent("\(base)-\(n)"); n += 1 }
        do { try FileManager.default.moveItem(at: url, to: aside) } catch { return ([], error) }
        return ([], nil)
    }
}
