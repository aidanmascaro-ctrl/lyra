import XCTest
@testable import LyraCore

final class CallWindowRuleTests: XCTestCase {
    private func w(_ id: UInt32, _ title: String, _ width: Double = 1200, _ height: Double = 800) -> WindowInfo {
        WindowInfo(id: id, title: title, width: width, height: height)
    }

    func testBrowserOnlyTheCallsTab() {
        let windows = [w(1, "Inbox (3) - aidan@example.com - Gmail - Google Chrome", 1600, 1000),
                       w(2, "Meet - abc-defg-hij - Google Chrome - Aidan")]
        XCTAssertEqual(CallWindowRule.pick(windows, appName: "Google Chrome", startTitle: "Meet - abc-defg-hij")?.id, 2)
        XCTAssertEqual(CallWindowRule.pick(windows, appName: "Google Chrome", startTitle: "")?.id, 2, "by its site")
    }

    /// The call tab is behind another tab: Lyra reads nothing rather than the tab in front.
    func testBrowserWithNoCallTabInFrontGivesNothing() {
        let windows = [w(1, "Inbox (3) - Gmail - Google Chrome"), w(2, "Meeting notes - Google Docs - Google Chrome")]
        XCTAssertNil(CallWindowRule.pick(windows, appName: "Google Chrome", startTitle: "Elm Park Startup Series"))
    }

    func testTeamsAndZoomInABrowser() {
        XCTAssertEqual(CallWindowRule.pick([w(1, "Weekly sync | Microsoft Teams - Google Chrome")], appName: "Google Chrome", startTitle: "x")?.id, 1)
        XCTAssertEqual(CallWindowRule.pick([w(1, "Zoom Meeting - Google Chrome")], appName: "Google Chrome", startTitle: "x")?.id, 1)
    }

    /// Gmail in front at Allow made the meeting's title Gmail's; it still isn't a call tab.
    func testStartTitleNeverMakesANonCallTabACall() {
        let windows = [w(1, "Inbox (3) - aidan@example.com - Gmail - Google Chrome", 1600, 1000),
                       w(2, "Meet - abc-defg-hij - Google Chrome")]
        XCTAssertEqual(CallWindowRule.pick(windows, appName: "Google Chrome", startTitle: "Inbox (3) - aidan@example.com - Gmail")?.id, 2)
        XCTAssertNil(CallWindowRule.pick([windows[0]], appName: "Google Chrome", startTitle: "Inbox (3) - aidan@example.com - Gmail"))
    }

    /// An email about Zoom is not a Zoom call.
    func testMentionsOfCallSitesAreNotCalls() {
        let windows = [w(1, "Your Zoom receipt - Gmail - Google Chrome", 1600, 1000), w(2, "Teams roster - Google Sheets - Google Chrome"),
                       w(3, "Meeting notes - Google Docs - Google Chrome")]
        XCTAssertNil(CallWindowRule.pick(windows, appName: "Google Chrome", startTitle: ""))
        XCTAssertNil(CallWindowRule.pick(windows, appName: "Vivaldi", startTitle: ""), "every browser follows the tab rule")
    }

    /// WhatsApp's chat list is never read; only a window titled as the call is.
    func testDesktopAppsOnlyTheirCallWindow() {
        XCTAssertNil(CallWindowRule.pick([w(1, "WhatsApp", 1400, 900)], appName: "WhatsApp", startTitle: "WhatsApp"))
        XCTAssertEqual(CallWindowRule.pick([w(1, "WhatsApp", 1400, 900), w(2, "Video call", 600, 800)], appName: "WhatsApp", startTitle: "")?.id, 2)
    }

    func testZoomAppPrefersItsMeetingWindow() {
        let windows = [w(1, "Zoom Workplace", 1600, 1000), w(2, "Zoom Meeting"), w(3, "", 300, 40)]
        XCTAssertEqual(CallWindowRule.pick(windows, appName: "zoom.us", startTitle: "zoom.us")?.id, 2)
    }

    func testFaceTimeItsLargestWindow() {
        let windows = [w(1, "FaceTime", 900, 700), w(2, "", 1200, 800), w(3, "", 100, 100)]
        XCTAssertEqual(CallWindowRule.pick(windows, appName: "FaceTime", startTitle: "FaceTime")?.id, 2)
        XCTAssertNil(CallWindowRule.pick([w(3, "", 100, 100)], appName: "FaceTime", startTitle: ""))
    }
}

final class RecordingClockTests: XCTestCase {
    private final class Time: @unchecked Sendable { var now: TimeInterval = 100 }

    func testLeavesOutPausedTime() {
        let time = Time()
        var clock = RecordingClock(now: { time.now })
        time.now = 110
        XCTAssertEqual(clock.seconds, 10)
        clock.pause()
        time.now = 150
        XCTAssertEqual(clock.seconds, 10, "stands still while paused")
        clock.resume()
        time.now = 155
        XCTAssertEqual(clock.seconds, 15)
    }
}

final class CallWindowRuleScreenTests: XCTestCase {
    /// A call window on this desktop wins over a bigger one that isn't.
    func testPrefersTheCallWindowOnThisDesktop() {
        let windows = [WindowInfo(id: 1, title: "Zoom Meeting", width: 2000, height: 1200, isOnScreen: false),
                       WindowInfo(id: 2, title: "Zoom Meeting", width: 1000, height: 700)]
        XCTAssertEqual(CallWindowRule.pick(windows, appName: "zoom.us", startTitle: "")?.id, 2)
    }

    /// Full screen on its own desktop: still picked, so the capture side can say where it was.
    func testOffScreenCallWindowIsStillPicked() {
        let window = WindowInfo(id: 1, title: "Zoom Meeting", width: 2000, height: 1200, isOnScreen: false)
        XCTAssertEqual(CallWindowRule.pick([window], appName: "zoom.us", startTitle: "")?.id, 1)
    }
}
