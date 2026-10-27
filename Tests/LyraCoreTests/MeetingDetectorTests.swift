import XCTest
@testable import LyraCore

final class MeetingDetectorTests: XCTestCase {
    let zoom = MicUser(pid: 100, bundleID: "us.zoom.xos", appName: "zoom.us")
    let chrome = MicUser(pid: 200, bundleID: "com.google.Chrome", appName: "Google Chrome")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func detector(ignored: Set<String> = []) -> MeetingDetector {
        detector(ignore: { ignored.contains($0.bundleID) })
    }

    func detector(ignore: @escaping (MicUser) -> Bool) -> MeetingDetector {
        MeetingDetector(ownPID: 1, ignore: ignore, endGrace: 10)
    }

    func testStartsOnceForNewMicUser() {
        let d = detector()
        var events: [DetectorEvent] = []
        for i in 0..<3 { events += d.update(users: [zoom], now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(events, [.meetingStarted(zoom)])
    }

    func testIgnoresOwnProcess() {
        let own = MicUser(pid: 1, bundleID: "app.lyra", appName: "Lyra")
        XCTAssertEqual(detector().update(users: [own], now: t0), [])
    }

    func testIgnoresSecondAppWhileRecording() {
        let d = detector()
        d.isRecording = true
        XCTAssertEqual(d.update(users: [chrome], now: t0), [])
    }

    func testIgnoresSecondAppWhileRecordingStartedByZoom() {
        let d = detector()
        XCTAssertEqual(d.update(users: [zoom], now: t0), [.meetingStarted(zoom)])
        d.isRecording = true
        XCTAssertEqual(d.update(users: [zoom, chrome], now: t0.addingTimeInterval(1)), [])
    }

    func testAppPresentWhenRecordingStopsDoesNotReprompt() {
        let d = detector()
        _ = d.update(users: [zoom], now: t0)
        d.isRecording = true
        _ = d.update(users: [zoom, chrome], now: t0.addingTimeInterval(1))
        _ = d.update(users: [chrome], now: t0.addingTimeInterval(2))
        XCTAssertEqual(d.update(users: [chrome], now: t0.addingTimeInterval(13)), [.meetingEnded(zoom)])
        d.isRecording = false
        XCTAssertEqual(d.update(users: [chrome], now: t0.addingTimeInterval(14)), [])
        XCTAssertEqual(d.update(users: [chrome], now: t0.addingTimeInterval(15)), [])
    }

    func testManualStartWithAppPresentDoesNotPromptAfterStop() {
        let d = detector()
        d.isRecording = true
        XCTAssertEqual(d.update(users: [zoom], now: t0), [])
        d.isRecording = false
        XCTAssertEqual(d.update(users: [zoom], now: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(d.update(users: [], now: t0.addingTimeInterval(2)), [])
        XCTAssertEqual(d.update(users: [zoom], now: t0.addingTimeInterval(13)), [.meetingStarted(zoom)])
    }

    func testBriefDropOfSuppressedAppDoesNotRepromptAfterStop() {
        let d = detector()
        d.isRecording = true
        XCTAssertEqual(d.update(users: [zoom, chrome], now: t0), [])
        XCTAssertEqual(d.update(users: [zoom], now: t0.addingTimeInterval(1)), [])
        d.isRecording = false
        XCTAssertEqual(d.update(users: [zoom, chrome], now: t0.addingTimeInterval(2)), [])
    }

    func testAppAbsentLongerThanGraceThenReturningPrompts() {
        let d = detector()
        d.isRecording = true
        XCTAssertEqual(d.update(users: [zoom, chrome], now: t0), [])
        XCTAssertEqual(d.update(users: [zoom], now: t0.addingTimeInterval(1)), [])
        d.isRecording = false
        XCTAssertEqual(d.update(users: [], now: t0.addingTimeInterval(12)), [])
        XCTAssertEqual(d.update(users: [chrome], now: t0.addingTimeInterval(13)), [.meetingStarted(chrome)])
    }

    func testEndsAfterGrace() {
        let d = detector()
        _ = d.update(users: [zoom], now: t0)
        XCTAssertEqual(d.update(users: [], now: t0.addingTimeInterval(5)), [])
        XCTAssertEqual(d.update(users: [], now: t0.addingTimeInterval(11)), [.meetingEnded(zoom)])
    }

    func testBriefDropDoesNotEnd() {
        let d = detector()
        _ = d.update(users: [zoom], now: t0)
        XCTAssertEqual(d.update(users: [], now: t0.addingTimeInterval(5)), [])
        XCTAssertEqual(d.update(users: [zoom], now: t0.addingTimeInterval(6)), [])
        XCTAssertEqual(d.update(users: [], now: t0.addingTimeInterval(12)), [])
    }

    func testIgnoredBundle() {
        let memos = MicUser(pid: 300, bundleID: "com.apple.VoiceMemos", appName: "Voice Memos")
        XCTAssertEqual(detector(ignored: ["com.apple.VoiceMemos"]).update(users: [memos], now: t0), [])
    }

    func testDetectorSkipsIgnoredApp() {
        let d = detector(ignore: { $0 == self.zoom })
        XCTAssertEqual(d.update(users: [zoom], now: t0), [])
        XCTAssertEqual(d.update(users: [zoom, chrome], now: t0.addingTimeInterval(1)), [.meetingStarted(chrome)])
    }

    /// Ignoring a long-running mic user must not block detection of every other app.
    func testDismissLetsOtherAppsPromptButNotTheIgnoredOne() {
        let d = detector()
        XCTAssertEqual(d.update(users: [zoom], now: t0), [.meetingStarted(zoom)])
        d.dismiss()
        XCTAssertEqual(d.update(users: [zoom], now: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(d.update(users: [zoom, chrome], now: t0.addingTimeInterval(2)), [.meetingStarted(chrome)])
        d.dismiss()
        var later: [DetectorEvent] = []  // both keep the mic, polled every second as the app does
        for i in 3...30 { later += d.update(users: [zoom, chrome], now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(later, [])
    }
}
