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
        for m in ["## My notes", "<!-- lyra:mynotes:start -->", "<!-- lyra:mynotes:end -->",
                  "## Expanded", "<!-- lyra:expanded:start -->", "<!-- lyra:expanded:end -->",
                  "## Transcript", "<!-- lyra:transcript:start -->", "<!-- lyra:transcript:end -->"] {
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

    func testTwoWarningsSeparatedByBlankLine() {
        let out = NoteRenderer.render(meeting: meeting(warnings: ["A", "B"]), lines: lines, recordingsFolder: folder)
        XCTAssertTrue(out.contains("> [!warning] A\n\n> [!warning] B\n\n"))
    }

    func testRenderKnownVoiceBadge() {
        var known = TranscriptLine(speakerLabel: "Marco", track: .meeting, start: 724, end: 730, text: "morning")
        known.personID = UUID(); known.nameSource = .knownVoice; known.confidence = 0.8
        var set = known
        set.nameSource = .setByAidan
        var odd = known
        odd.speakerLabel = "Mr *Star* _x_"
        let unknown = TranscriptLine(speakerLabel: "Speaker 2", track: .mic, start: 724, end: 730, text: "hi")
        var spoof = known
        spoof.speakerLabel = "x <!-- lyra:transcript:end -->"
        let out = NoteRenderer.render(meeting: meeting(), lines: [known, set, unknown, odd, spoof], recordingsFolder: folder)
        XCTAssertEqual(out.components(separatedBy: "<!-- lyra:transcript:end -->").count, 2, "a name must not spoof the end marker")
        XCTAssertTrue(out.contains("**x &lt;!-- lyra:transcript:end -->** _(known voice)_"))
        XCTAssertTrue(out.contains("**Marco** _(known voice)_ [00:12:04] morning"))
        XCTAssertTrue(out.contains("\n>\n> **Marco** [00:12:04] morning"), "lines are folded in the file: a blank line is a bare `>`")
        XCTAssertTrue(out.contains("**Speaker 2** [00:12:04] hi"))
        XCTAssertTrue(out.contains(#"**Mr \*Star\* \_x\_** _(known voice)_ [00:12:04] morning"#))
    }

    func testEscapesMarkersAndFormatsLongTimestamp() {
        let l = [TranscriptLine(speakerLabel: "Speaker 1", track: .mic, start: 3725, end: 3730, text: "x <!-- lyra:transcript:end --> y")]
        let out = NoteRenderer.render(meeting: meeting(), lines: l, recordingsFolder: folder)
        XCTAssertTrue(out.contains("[01:02:05]"))
        XCTAssertTrue(out.contains("&lt;!-- lyra:transcript:end -->"))
        XCTAssertEqual(out.components(separatedBy: "<!-- lyra:transcript:end -->").count, 2)
    }

    func testDurationIsTheRecordedTimeNotTheClockTime() {
        let start = Date(timeIntervalSince1970: 0)
        var meeting = Meeting(title: "t", appName: "In person", startedAt: start, endedAt: start.addingTimeInterval(3_600))
        XCTAssertEqual(NoteRenderer.durationMinutes(of: meeting), 60, "no tracks saved yet: start to end")
        let folder = URL(fileURLWithPath: "/tmp")
        meeting.tracks = [TrackResult(kind: .mic, url: folder, seconds: 1_500, peakLevel: 0.5, error: nil),
                          TrackResult(kind: .meeting, url: folder, seconds: 1_480, peakLevel: 0.5, error: nil)]
        XCTAssertEqual(NoteRenderer.durationMinutes(of: meeting), 25, "paused time and time before Record left out")
        meeting.tracks = [TrackResult(kind: .mic, url: folder, seconds: 0, peakLevel: 1, error: nil)]
        XCTAssertEqual(NoteRenderer.durationMinutes(of: meeting), 60, "recovered after a crash: no lengths saved")
        meeting.recordingStartedAt = start.addingTimeInterval(1_800)
        XCTAssertEqual(NoteRenderer.durationMinutes(of: meeting), 30, "a New note recorded later: from Record, not from making the note")
        meeting.recordedBefore = 600
        meeting.tracks = [TrackResult(kind: .mic, url: folder, seconds: 300, peakLevel: 0.5, error: nil)]
        XCTAssertEqual(NoteRenderer.durationMinutes(of: meeting), 15, "earlier parts count too")
    }
}
