import Security
import XCTest
@testable import Lyra

final class KeychainSecretStoreTests: XCTestCase {
    func testErrorSaysItWasTheKeychainAndNotASignOut() {
        let message = KeychainError(status: errSecAuthFailed).localizedDescription
        XCTAssertTrue(message.contains("Keychain"), message)
    }

    /// Uses the real login Keychain under a throwaway service name, so never Lyra's own entries.
    func testRealKeychainWritesReadsReplacesAndDeletes() throws {
        guard ProcessInfo.processInfo.environment["LYRA_INTEGRATION"] == "1" else {
            throw XCTSkip("set LYRA_INTEGRATION=1 to run integration tests")
        }
        let store = KeychainSecretStore(service: "au.aidos.lyra.test.\(UUID().uuidString)")
        defer { try? store.delete("account") }

        XCTAssertNil(try store.read("account"))
        try store.write(Data("first".utf8), for: "account")
        XCTAssertEqual(try store.read("account"), Data("first".utf8))
        try store.write(Data("second".utf8), for: "account")
        XCTAssertEqual(try store.read("account"), Data("second".utf8))
        try store.delete("account")
        XCTAssertNil(try store.read("account"))
        XCTAssertNoThrow(try store.delete("account"), "deleting what isn't there is fine")
    }
}
