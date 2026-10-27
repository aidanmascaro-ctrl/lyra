import XCTest
@testable import Lyra

/// Double-clicking the top bar does what System Settings › Desktop & Dock says, like any other Mac window.
final class TitleBarStripTests: XCTestCase {
    func testNoSettingZoomsLikeTheMacDefault() {
        XCTAssertEqual(TitleBarStrip.Action(setting: nil), .zoom)
    }

    func testZoomAndFillBothZoom() {
        XCTAssertEqual(TitleBarStrip.Action(setting: "Maximize"), .zoom)
        XCTAssertEqual(TitleBarStrip.Action(setting: "Fill"), .zoom)
    }

    func testMinimizeSettingMinimises() {
        XCTAssertEqual(TitleBarStrip.Action(setting: "Minimize"), .minimize)
    }

    func testDoNothingSettingDoesNothing() {
        XCTAssertEqual(TitleBarStrip.Action(setting: "None"), .none)
    }
}
