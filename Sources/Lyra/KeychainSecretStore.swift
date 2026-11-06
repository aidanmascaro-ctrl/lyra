import Foundation
import LyraCore
import Security

/// The login Keychain. Entries belong to the app that made them, so a build signed with the same certificate reads
/// them without asking and other apps have to ask. They don't sync to iCloud. (The newer "data protection" Keychain
/// needs an entitlement a self-signed app can't have.)
struct KeychainSecretStore: SecretStore {
    static let calendarService = "au.aidos.lyra.calendar-tokens"

    let service: String

    func read(_ key: String) throws -> Data? {
        var query = identity(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    func write(_ data: Data, for key: String) throws {
        let updated = SecItemUpdate(identity(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var item = identity(key)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Lyra calendar sign-in"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    func delete(_ key: String) throws {
        let status = SecItemDelete(identity(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func identity(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "The Keychain didn't allow it (\(SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"))"
    }
}
