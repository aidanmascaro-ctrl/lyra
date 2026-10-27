import Foundation

/// An app the user chose to never be prompted about. `key` is the bundle ID, or "name:<appName>" when the app has none.
public struct IgnoredApp: Codable, Hashable, Sendable {
    public let key: String
    public let name: String

    public init(user: MicUser) {
        key = Self.key(for: user)
        name = user.appName
    }

    static func key(for user: MicUser) -> String {
        user.bundleID.isEmpty ? "name:\(user.appName)" : user.bundleID
    }
}

/// The saved list of ignored apps. Reads and writes go straight to `defaults`, so every instance sees the same list.
public final class IgnoredApps: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults, key: String = "ignoredApps") {
        self.defaults = defaults
        self.key = key
    }

    public func all() -> [IgnoredApp] {
        lock.withLock { load() }
    }

    public func add(_ app: IgnoredApp) {
        lock.withLock {
            let current = load()
            guard !current.contains(where: { $0.key == app.key }) else { return }
            save(current + [app])
        }
    }

    public func remove(_ app: IgnoredApp) {
        lock.withLock { save(load().filter { $0.key != app.key }) }
    }

    public func contains(_ user: MicUser) -> Bool {
        let wanted = IgnoredApp.key(for: user)
        return all().contains { $0.key == wanted }
    }

    private func load() -> [IgnoredApp] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IgnoredApp].self, from: data)) ?? []
    }

    private func save(_ apps: [IgnoredApp]) {
        defaults.set(try? JSONEncoder().encode(apps), forKey: key)
    }
}
