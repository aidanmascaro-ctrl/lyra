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
        XCTAssertEqual(out, note.replacingOccurrences(of: "**Speaker 1** [00:00:00] hello",
                                                      with: "> [!quote]- Full transcript\n> **Marco** [00:00:00] hello"))
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

    /// In the file the transcript sits in a folded Obsidian callout (`> [!quote]- …`), so a long note opens short;
    /// Lyra reads and hashes the plain lines, and a note written before the fold still reads the same.
    func testTranscriptIsFoldedInTheFileButPlainToLyra() throws {
        let plain = "**Marco** [00:00:00] hello\n\n**Aidan** [00:00:04] hi"
        let out = try NoteSections.replaceTranscript(in: note, with: plain)
        XCTAssertTrue(out.contains("<!-- lyra:transcript:start -->\n> [!quote]- Full transcript\n> **Marco** [00:00:00] hello\n>\n> **Aidan** [00:00:04] hi\n<!-- lyra:transcript:end -->"), out)
        XCTAssertEqual(NoteSections.transcriptBody(of: out), plain)
        XCTAssertEqual(NoteSections.transcriptBody(of: note), "**Speaker 1** [00:00:00] hello", "old plain layout")
        let empty = try NoteSections.replaceTranscript(in: note, with: "")
        XCTAssertFalse(empty.contains("[!quote]"), "nothing to fold")
        XCTAssertEqual(NoteSections.transcriptBody(of: empty), "")
    }

    /// Obsidian keeps the `> ` on an edited line and may add a line without it; both come back as plain text.
    func testUnfoldTakesEditedLinesAsTheyAre() {
        let body = "> [!quote]- Full transcript\n> **A** [00:00:00] fixed word\n>\n> **B** [00:00:02] x\nadded without prefix"
        XCTAssertEqual(NoteSections.unfold(body), "**A** [00:00:00] fixed word\n\n**B** [00:00:02] x\nadded without prefix")
        XCTAssertEqual(NoteSections.fold("a\n\nb"), "> [!quote]- Full transcript\n> a\n>\n> b")
        XCTAssertEqual(NoteSections.fold(""), "")
        XCTAssertEqual(NoteSections.unfold("plain"), "plain")
    }

    /// SHA-256 of the empty string is the well-known e3b0c442…b855.
    func testHash() {
        let h = NoteSections.hash("")
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.hasPrefix("e3b0c442") && h.hasSuffix("7852b855"))
        XCTAssertNotEqual(NoteSections.hash("a"), h)
    }
}
