import Foundation

/// One signed-in calendar account (Aidan has a Google one and work + personal Microsoft ones).
public struct CalendarAccount: Codable, Equatable, Identifiable, Sendable {
    public let provider: CalendarProvider
    /// From the sign-in; "" when the provider didn't say.
    public let email: String
    /// The app details it signed in with: its tokens only refresh with these.
    public let client: OAuthClient
    public var tokens: OAuthTokens

    public init(provider: CalendarProvider, email: String, client: OAuthClient, tokens: OAuthTokens) {
        self.provider = provider
        self.email = email
        self.client = client
        self.tokens = tokens
    }

    public var id: String { provider.rawValue + ":" + email.lowercased() }
    public var label: String { email.isEmpty ? provider.name : email }
}

/// What Lyra keeps to read calendars: the app details Aidan registered with each provider, and each account's
/// tokens. An owner-only file in Application Support (not the Keychain: the app is ad-hoc signed, and the Keychain
/// would ask again after every rebuild).
public struct CalendarSettings: Codable, Equatable, Sendable {
    /// The app details for new sign-ins, by provider raw value.
    public var clients: [String: OAuthClient] = [:]
    public var accounts: [CalendarAccount] = []

    public init() {}

    public func client(for provider: CalendarProvider) -> OAuthClient? { clients[provider.rawValue] }

    /// The account added, replacing an earlier sign-in to the same account.
    public func adding(_ account: CalendarAccount) -> CalendarSettings {
        var copy = self
        copy.accounts = accounts.filter { $0.id != account.id } + [account]
        return copy
    }

    public func removing(accountID: String) -> CalendarSettings {
        var copy = self
        copy.accounts = accounts.filter { $0.id != accountID }
        return copy
    }

    public func setting(_ client: OAuthClient?, for provider: CalendarProvider) -> CalendarSettings {
        var copy = self
        copy.clients[provider.rawValue] = client
        return copy
    }

    public func updating(tokens: OAuthTokens, for accountID: String) -> CalendarSettings {
        var copy = self
        copy.accounts = accounts.map { account in
            guard account.id == accountID else { return account }
            var updated = account
            updated.tokens = tokens
            return updated
        }
        return copy
    }
}

public struct CalendarStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lyra/calendars.json")
    }

    /// Empty settings when Lyra was never connected.
    public func load() throws -> CalendarSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return CalendarSettings() }
        return try JSONDecoder().decode(CalendarSettings.self, from: Data(contentsOf: fileURL))
    }

    /// Written owner-only from the start (a temporary file, then renamed over the old one), never readable by others.
    public func save(_ settings: CalendarSettings) throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(settings),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
