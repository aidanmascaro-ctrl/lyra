import XCTest
@testable import LyraCore

final class DockPolicyTests: XCTestCase {
    private func w(_ id: Int, panel: Bool = false, titled: Bool = true, visible: Bool = true, minimised: Bool = false) -> DockPolicy.Window {
        DockPolicy.Window(id: id, isPanel: panel, isTitled: titled, isVisible: visible, isMiniaturized: minimised)
    }

    func testOpenWindowMakesADockApp() {
        XCTAssertTrue(DockPolicy.showsInDock([w(1)], closing: []))
    }

    func testLastWindowClosingGoesBackToTheMenuBar() {
        XCTAssertFalse(DockPolicy.showsInDock([], closing: []))
        XCTAssertFalse(DockPolicy.showsInDock([w(1, visible: false)], closing: []))
    }

    func testClosingWindowIsExcludedEvenWhileItStillReportsVisible() {
        XCTAssertFalse(DockPolicy.showsInDock([w(1)], closing: [1]))
        XCTAssertTrue(DockPolicy.showsInDock([w(1), w(2)], closing: [1]))
    }

    func testMinimisedWindowCountsAsOpen() {
        XCTAssertTrue(DockPolicy.showsInDock([w(1, visible: false, minimised: true)], closing: []))
    }

    func testPanelsAndTheStatusItemDoNotCount() {
        XCTAssertFalse(DockPolicy.showsInDock([w(1, panel: true), w(2, titled: false)], closing: []))
    }

    func testReopenWithNoLyraWindowOpensHome() {
        XCTAssertEqual(DockPolicy.reopen([w(1, panel: true), w(2, titled: false)], closing: []), .openHome)
        XCTAssertEqual(DockPolicy.reopen([w(1)], closing: [1]), .openHome)
    }

    func testReopenRestoresMinimisedWindowsInsteadOfOpeningHome() {
        XCTAssertEqual(DockPolicy.reopen([w(1, visible: false, minimised: true), w(2)], closing: []), .front(restore: [1]))
        XCTAssertEqual(DockPolicy.reopen([w(2)], closing: []), .front(restore: []))
    }
}
