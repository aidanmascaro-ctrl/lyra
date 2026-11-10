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

    func testMenuBarClickHidesLyraWhenItIsInFrontWithAWindowShowing() {
        XCTAssertEqual(DockPolicy.menuBarClick([w(1)], closing: [], isActive: true, isHidden: false), .hide)
    }

    func testMenuBarClickShowsLyraWhenAnotherAppIsInFront() {
        XCTAssertEqual(DockPolicy.menuBarClick([w(1)], closing: [], isActive: false, isHidden: false), .show)
    }

    func testMenuBarClickShowsLyraWhenItIsHidden() {
        XCTAssertEqual(DockPolicy.menuBarClick([w(1, visible: false)], closing: [], isActive: true, isHidden: true), .show)
    }

    func testMenuBarClickShowsLyraWhenItsOnlyWindowIsMinimisedOrClosed() {
        XCTAssertEqual(DockPolicy.menuBarClick([w(1, visible: false, minimised: true)], closing: [], isActive: true, isHidden: false), .show)
        XCTAssertEqual(DockPolicy.menuBarClick([], closing: [], isActive: true, isHidden: false), .show)
        XCTAssertEqual(DockPolicy.menuBarClick([w(1)], closing: [1], isActive: true, isHidden: false), .show)
    }

    func testMenuBarClickIgnoresPanelsWhenDecidingToHide() {
        // Only the Allow prompt (a panel) is up: there is no Lyra window to hide, so the click shows home.
        XCTAssertEqual(DockPolicy.menuBarClick([w(1, panel: true)], closing: [], isActive: true, isHidden: false), .show)
    }
}
