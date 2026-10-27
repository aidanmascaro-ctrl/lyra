import AppKit
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

    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let window = NSRect(x: 200, y: 100, width: 820, height: 760)

    func testFirstDoubleClickFillsTheScreenAndRemembersTheOldSize() {
        let step = TitleBarStrip.zoomStep(current: window, screen: screen, saved: nil)
        XCTAssertEqual(step.frame, screen)
        XCTAssertEqual(step.saved, window)
    }

    func testSecondDoubleClickGoesBackToTheOldSize() {
        let step = TitleBarStrip.zoomStep(current: screen, screen: screen, saved: window)
        XCTAssertEqual(step.frame, window)
        XCTAssertNil(step.saved)
    }

    func testAWindowMovedAfterFillingFillsAgainInsteadOfJumpingBack() {
        let moved = NSRect(x: 300, y: 50, width: 900, height: 700)
        let step = TitleBarStrip.zoomStep(current: moved, screen: screen, saved: window)
        XCTAssertEqual(step.frame, screen)
        XCTAssertEqual(step.saved, moved)
    }

    func testAWindowAlreadyFillingWithNothingSavedGetsAQuarterSmaller() {
        let step = TitleBarStrip.zoomStep(current: screen, screen: screen, saved: nil)
        XCTAssertLessThan(step.frame.width, screen.width)
        XCTAssertTrue(screen.contains(step.frame))
        XCTAssertNil(step.saved)
    }
}

/// The recording bars follow the sound: flat and low in silence, taller as it gets louder, never past their box.
final class LevelDotsTests: XCTestCase {
    func testSilenceIsFlat() {
        let heights = LevelDots.heights(peak: 0, time: 1.7)
        XCTAssertEqual(Set(heights), [LevelDots.minHeight])
    }

    func testLouderIsTaller() {
        let quiet = LevelDots.heights(peak: 0.01, time: 1.7).reduce(0, +)
        let loud = LevelDots.heights(peak: 0.5, time: 1.7).reduce(0, +)
        XCTAssertGreaterThan(loud, quiet)
    }

    func testNeverTallerThanTheBox() {
        for t in stride(from: 0.0, to: 3, by: 0.1) {
            XCTAssertTrue(LevelDots.heights(peak: 1, time: t).allSatisfy { $0 <= LevelDots.maxHeight })
        }
    }
}
