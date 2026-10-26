import XCTest
@testable import LyraCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(LyraCore.version, "0.1.0")
    }
}
