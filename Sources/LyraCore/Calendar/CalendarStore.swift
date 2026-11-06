import Foundation

/// One signed-in calendar account (Aidan has a Google one and work + personal Microsoft ones).
public struct CalendarAccount: Codable, Equatable, Identifiable, Sendable {
    public let provider: CalendarProvider
    /// From the sign-in; "" when the provider didn't say.
    public let email: String
    /// The app details it signed in with: its tokens only refresh with these.
    public let client: OAuthClient
    /// Only on an account from before tokens moved to the Keychain, until `migrateLegacyTokens` has safely moved them.
    var legacyTokens: OAuthTokens?

    enum CodingKeys: String, CodingKey {
        case provider, email, client
        case legacyTokens = "tokens"
    }

    public init(provider: CalendarProvider, email: String, client: OAuthClient) {
        self.provider = provider
        self.email = email
        self.client = client
    }

    public var id: String { provider.rawValue + ":" + email.lowercased() }
    public var label: String { email.isEmpty ? provider.name : email }
}

/// What Lyra keeps in its owner-only file to read calendars: the app details Aidan registered with each provider, and
/// which accounts are connected. The accounts' tokens are in the Keychain (see `CalendarStore`).
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

    func withLegacyTokens(_ tokens: OAuthTokens?, for accountID: String) -> CalendarSettings {
        var copy = self
        copy.accounts = accounts.map { account in
            guard account.id == accountID else { return account }
            var updated = account
            updated.legacyTokens = tokens
            return updated
        }
        return copy
    }
}

/// The settings file, and each account's tokens in a `SecretStore` under the account's id.
public struct CalendarStore: Sendable {
    public let fileURL: URL
    private let secrets: any SecretStore

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

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
    /// An account's tokens, or nil when it has none and must sign in again. Tokens still in the file are used if the
    /// Keychain can't be read or holds an older copy.
    public func tokens(for accountID: String) throws -> OAuthTokens? {
        let legacy = try load().accounts.first { $0.id == accountID }?.legacyTokens
        do {
            let stored = try storedTokens(for: accountID)
            guard let stored, let legacy else { return stored ?? legacy }
            return stored.expiresAt >= legacy.expiresAt ? stored : legacy
        } catch {
            guard let legacy else { throw error }
            return legacy
        }
    }

    /// Saves to the Keychain and reads it back: this only returns if the tokens can really be got out again.
    public func storeTokens(_ tokens: OAuthTokens, for accountID: String) throws {
        let data = try JSONEncoder().encode(tokens)
        try secrets.write(data, for: accountID)
        guard try secrets.read(accountID) == data else { throw CalendarError.tokensNotSaved }
    }

    /// Saves refreshed tokens. If the Keychain refuses and this account hasn't moved yet, they stay in the file they
    /// were already in, so a rotated token isn't lost; a moved account never goes back to the file.
    public func updateTokens(_ tokens: OAuthTokens, for accountID: String) throws {
        let settings = try load()
        // Removed while its refresh was on the network: saving now would leave tokens behind that nothing cleans up.
        guard let account = settings.accounts.first(where: { $0.id == accountID }) else { return }
        let unmoved = account.legacyTokens != nil
        do {
            try storeTokens(tokens, for: accountID)
        } catch {
            guard unmoved else { throw error }
            return try save(settings.withLegacyTokens(tokens, for: accountID))
        }
        if unmoved { try save(settings.withLegacyTokens(nil, for: accountID)) }
    }

    public func deleteTokens(for accountID: String) throws { try secrets.delete(accountID) }

    /// Moves tokens left in the file by earlier versions to the Keychain. Each leaves the file only after it has been
    /// read back from the Keychain, so a failure loses nothing and is tried again next launch. Answers how many
    /// accounts couldn't be moved; does nothing at all once none are left.
    public func migrateLegacyTokens() throws -> Int {
        let settings = try load()
        var moved = settings
        var waiting = 0
        for account in settings.accounts {
            guard let legacy = account.legacyTokens else { continue }
            do {
                // A newer copy means an earlier move got this far and then couldn't rewrite the file.
                let stored = try storedTokens(for: account.id)
                if (stored?.expiresAt ?? .distantPast) < legacy.expiresAt { try storeTokens(legacy, for: account.id) }
                moved = moved.withLegacyTokens(nil, for: account.id)
            } catch {
                waiting += 1
            }
        }
        if moved != settings { try save(moved) }
        return waiting
    }

    /// An entry that can't be understood counts as none: signing in again replaces it.
    private func storedTokens(for accountID: String) throws -> OAuthTokens? {
        try secrets.read(accountID).flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
    }
}
