import XCTest

/// Call first in every integration test; skips unless LYRA_INTEGRATION=1.
func requireIntegration() throws {
    guard ProcessInfo.processInfo.environment["LYRA_INTEGRATION"] == "1" else {
        throw XCTSkip("set LYRA_INTEGRATION=1 to run integration tests")
    }
}
