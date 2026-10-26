import LyraCore
import XCTest

final class NoteSectionsTests: XCTestCase {
    private let note = """
    ---
    lyra_id: X
    ---
    # Call

    ## Notes
    <!-- lyra:notes:start -->
    my own notes
    <!-- lyra:notes:end -->

    ## Transcript
    <!-- lyra:transcript:start -->
    **Speaker 1** [00:00:00] hello
    <!-- lyra:transcript:end -->

    Aidan's footer

    """

    func testTranscriptBody() {
        XCTAssertEqual(NoteSections.transcriptBody(of: note), "**Speaker 1** [00:00:00] hello")
        XCTAssertNil(NoteSections.transcriptBody(of: "no markers"))
    }

    func testReplaceTranscriptKeepsOutsideEdits() throws {
        let out = try NoteSections.replaceTranscript(in: note, with: "**Marco** [00:00:00] hello")
        XCTAssertEqual(out, note.replacingOccurrences(of: "**Speaker 1**", with: "**Marco**"))
        XCTAssertEqual(NoteSections.transcriptBody(of: out), "**Marco** [00:00:00] hello")
        XCTAssertThrowsError(try NoteSections.replaceTranscript(in: "no markers", with: "x"))
    }

    func testBodyMatchesRenderer() {
        let meeting = Meeting(title: "Call", appName: "zoom.us", startedAt: Date(timeIntervalSince1970: 0))
        for lines in [[], [TranscriptLine(speakerLabel: "Speaker 1", track: .meeting, start: 0, end: 1, text: "hi")]] {
            let rendered = NoteRenderer.render(meeting: meeting, lines: lines, recordingsFolder: URL(fileURLWithPath: "/tmp"))
            XCTAssertEqual(NoteSections.transcriptBody(of: rendered), NoteRenderer.transcriptBody(lines: lines))
        }
    }

    /// SHA-256 of the empty string is the well-known e3b0c442…b855.
    func testHash() {
        let h = NoteSections.hash("")
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.hasPrefix("e3b0c442") && h.hasSuffix("7852b855"))
        XCTAssertNotEqual(NoteSections.hash("a"), h)
    }
}
