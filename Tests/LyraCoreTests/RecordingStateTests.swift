import LyraCore
import XCTest

final class RecordingStateTests: XCTestCase {
    private let zoom = MicUser(pid: 10, bundleID: "us.zoom.xos", appName: "zoom.us")
    private let teams = MicUser(pid: 11, bundleID: "com.microsoft.teams2", appName: "Teams")

    func testMeetingEndingDuringStartStopsRightAfterStart() {
        var s = RecordingState()
        XCTAssertTrue(s.begin(target: zoom))
        XCTAssertFalse(s.meetingEnded(zoom))   // nothing to stop yet
        XCTAssertTrue(s.started())             // so stop as soon as it is running
        XCTAssertEqual(s.phase, .idle)
    }

    func testMeetingEndStopsRecording() {
        var s = RecordingState()
        _ = s.begin(target: zoom)
        XCTAssertFalse(s.started())
        XCTAssertFalse(s.meetingEnded(teams))
        XCTAssertTrue(s.meetingEnded(zoom))
        XCTAssertEqual(s.phase, .idle)
    }

    func testStopButtonDuringStartAndFailedStart() {
        var s = RecordingState()
        _ = s.begin(target: nil)
        XCTAssertFalse(s.begin(target: zoom))  // one at a time
        XCTAssertFalse(s.requestStop())
        s.failed()
        XCTAssertEqual(s.phase, .idle)
        _ = s.begin(target: nil)
        XCTAssertFalse(s.started())            // the earlier stop request died with the failed start
    }

    func testInPersonIgnoresMeetingEnd() {
        var s = RecordingState()
        _ = s.begin(target: nil)
        _ = s.started()
        XCTAssertFalse(s.meetingEnded(zoom))
        XCTAssertTrue(s.requestStop())
    }

    func testPauseAndResumeOnlyWhileRecording() {
        var s = RecordingState()
        XCTAssertFalse(s.pause())               // nothing recording
        _ = s.begin(target: nil)
        XCTAssertFalse(s.pause())               // still starting
        _ = s.started()
        XCTAssertTrue(s.pause())
        XCTAssertEqual(s.phase, .paused(nil))
        XCTAssertFalse(s.pause())               // already paused
        XCTAssertTrue(s.resume())
        XCTAssertEqual(s.phase, .recording(nil))
        XCTAssertFalse(s.resume())              // already recording
    }

    func testEndWhilePausedStops() {
        var s = RecordingState()
        _ = s.begin(target: nil)
        _ = s.started()
        _ = s.pause()
        XCTAssertTrue(s.requestStop())
        XCTAssertEqual(s.phase, .idle)
    }

    func testCallEndingWhilePausedStops() {
        var s = RecordingState()
        _ = s.begin(target: zoom)
        _ = s.started()
        _ = s.pause()
        XCTAssertFalse(s.meetingEnded(teams))
        XCTAssertTrue(s.meetingEnded(zoom))
        XCTAssertEqual(s.phase, .idle)
    }
}
