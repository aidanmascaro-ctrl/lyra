import XCTest
@testable import LyraCore

final class NoteRendererTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/x/Lyra Recordings/m1", isDirectory: true)
    private func meeting(warnings: [String] = []) -> Meeting {
        Meeting(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Weekly sync",
                appName: "Zoom", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                endedAt: Date(timeIntervalSince1970: 1_800_000_000 + 52 * 60), warnings: warnings)
    }
    private let lines = [TranscriptLine(speakerLabel: "Speaker 1", track: .meeting, start: 4, end: 6, text: "hi all")]

    func testRenderHasMarkersAndTimestamps() {
        let out = NoteRenderer.render(meeting: meeting(), lines: lines, recordingsFolder: folder,
                                      timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        for m in ["<!-- lyra:notes:start -->", "<!-- lyra:notes:end -->",
                  "<!-- lyra:transcript:start -->", "<!-- lyra:transcript:end -->"] {
            XCTAssertTrue(out.contains(m), m)
        }
        XCTAssertTrue(out.contains("**Speaker 1** [00:00:04] hi all"))
        XCTAssertTrue(out.contains("lyra_id: 11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(out.contains("app: \"Zoom\""))
        XCTAssertTrue(out.contains("duration_min: 52"))
        XCTAssertTrue(out.contains("date: 2027-01-15T16:00:00+08:00"))
        XCTAssertTrue(out.contains("recordings: \"file:///Users/x/Lyra%20Recordings/m1/\""))
        XCTAssertTrue(out.contains("# Weekly sync"))
        XCTAssertFalse(out.contains("[!warning]"))
    }

    func testSilentMeetingTrackWarning() {
        let out = NoteRenderer.render(
            meeting: meeting(warnings: ["Meeting audio was silent — transcript is from your microphone only."]),
            lines: lines, recordingsFolder: folder)
        XCTAssertTrue(out.contains("> [!warning] Meeting audio was silent"))
    }
}
