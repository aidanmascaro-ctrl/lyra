import Foundation

/// Somewhere safer than a file to keep small secrets, by key. The app's is the macOS Keychain
/// (`KeychainSecretStore`); this target can't use it, and tests use a fake.
public protocol SecretStore: Sendable {
    /// Nil when nothing is saved under the key. Throws when it couldn't be read, which is not the same thing.
    func read(_ key: String) throws -> Data?
    /// Adds or replaces.
    func write(_ data: Data, for key: String) throws
    /// Fine if nothing is saved under the key.
    func delete(_ key: String) throws
}
