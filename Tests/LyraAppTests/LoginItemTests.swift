import ServiceManagement
import XCTest
@testable import Lyra

/// Open at Login reads what macOS says about Lyra's login item, so a change made in System Settings shows in Lyra.
final class LoginItemTests: XCTestCase {
    func testEnabledIsOn() {
        XCTAssertEqual(LoginItem.State(SMAppService.Status.enabled), .on)
    }

    func testWaitingForApprovalCountsAsOnButSaysSo() {
        let state = LoginItem.State(SMAppService.Status.requiresApproval)
        XCTAssertEqual(state, .needsApproval)
        XCTAssertTrue(state.isOn)
    }

    func testNotRegisteredIsOff() {
        XCTAssertEqual(LoginItem.State(SMAppService.Status.notRegistered), .off)
        XCTAssertFalse(LoginItem.State.off.isOn)
    }

    func testNotFoundIsOff() {
        XCTAssertEqual(LoginItem.State(SMAppService.Status.notFound), .off)
    }
}
