import XCTest
@testable import LyraCore

final class NoteDocumentTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 8 * 3600)!

    private func front() -> NoteFrontmatter {
        NoteFrontmatter(lyraID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Weekly sync",
                        date: Date(timeIntervalSince1970: 1_800_000_000), app: "Zoom", durationMin: 52,
                        recordings: URL(fileURLWithPath: "/Users/x/Lyra Recordings/m1", isDirectory: true),
                        series: "Elm Park Startup Series", tags: ["ai-consulting"], links: ["Northwind"],
                        summary: "Kick-off")
    }

    func testRendersThreeSectionsAndParsesBack() throws {
        let doc = NoteDocument(front: front(), warnings: ["Meeting audio was silent"], myNotes: "- hi",
                               expanded: "- <span class=\"lyra\">x</span>", transcript: "**Aidan** [00:00:01] hello")
        let out = doc.render(timeZone: zone)
        for expected in ["## My notes", "## Expanded", "## Transcript", "series: \"Elm Park Startup Series\"",
                         "tags: [meeting, ai-consulting]", "links: [\"[[Northwind]]\"]", "date: 2027-01-15T16:00:00+08:00",
                         "summary: \"Kick-off\"", "# Weekly sync", "> [!warning] Meeting audio was silent",
                         "<!-- lyra:mynotes:start -->", "<!-- lyra:expanded:end -->"] {
            XCTAssertTrue(out.contains(expected), expected)
        }
        XCTAssertEqual(try NoteDocument.parse(out), doc)
    }

    func testOptionalFieldsAreOmittedAndStillRoundTrip() throws {
        var f = front(); f.series = nil; f.summary = nil; f.tags = []; f.links = []
        let doc = NoteDocument(front: f, warnings: [], myNotes: "", expanded: "", transcript: "")
        let out = doc.render(timeZone: zone)
        XCTAssertFalse(out.contains("series:"))
        XCTAssertFalse(out.contains("summary:"))
        XCTAssertTrue(out.contains("tags: [meeting]"))
        XCTAssertEqual(try NoteDocument.parse(out), doc)
    }

    func testMissingSectionsReadAsEmpty() throws {
        let note = """
        ---
        lyra_id: 11111111-2222-3333-4444-555555555555
        date: 2027-01-15T16:00:00+08:00
        app: "Zoom"
        duration_min: 52
        recordings: "file:///x/"
        tags: [meeting]
        ---
        # Old note

        ## Transcript
        <!-- lyra:transcript:start -->
        **Aidan** [00:00:01] hello
        <!-- lyra:transcript:end -->

        """
        let doc = try NoteDocument.parse(note)
        XCTAssertEqual(doc.myNotes, "")
        XCTAssertEqual(doc.expanded, "")
        XCTAssertEqual(doc.transcript, "**Aidan** [00:00:01] hello")
        XCTAssertEqual(doc.front.title, "Old note")
        XCTAssertTrue(doc.render(timeZone: zone).contains("## My notes"))
    }

    func testReadsPhase2NoteNotesMarkersAsMyNotes() throws {
        let note = """
        ---
        lyra_id: 11111111-2222-3333-4444-555555555555
        date: 2027-01-15T16:00:00+08:00
        tags: [meeting]
        ---
        # Phase 2

        ## Notes
        <!-- lyra:notes:start -->
        - typed
        <!-- lyra:notes:end -->

        ## Transcript
        <!-- lyra:transcript:start -->
        t
        <!-- lyra:transcript:end -->

        """
        let doc = try NoteDocument.parse(note)
        XCTAssertEqual(doc.myNotes, "- typed")
        let out = doc.render(timeZone: zone)
        XCTAssertFalse(out.contains("lyra:notes:"))
        XCTAssertEqual(try NoteDocument.parse(out).myNotes, "- typed")
    }

    func testKeepsTextOutsideSectionsWhenReRendered() throws {
        let doc = NoteDocument(front: front(), warnings: [], myNotes: "- hi", expanded: "", transcript: "t")
        var out = doc.render(timeZone: zone)
        out = out.replacingOccurrences(of: "# Weekly sync\n\n", with: "# Weekly sync\n\nMy own paragraph.\n\n")
        out = out.replacingOccurrences(of: "<!-- lyra:expanded:end -->\n\n", with: "<!-- lyra:expanded:end -->\n\nBetween sections.\n\n")
        out += "Footer by Aidan\n"
        let reparsed = try NoteDocument.parse(out)
        XCTAssertEqual(reparsed.render(timeZone: zone), out)
    }

    func testKeepsUnknownFrontmatterKeys() throws {
        let doc = NoteDocument(front: front(), warnings: [], myNotes: "", expanded: "", transcript: "")
        let out = doc.render(timeZone: zone).replacingOccurrences(of: "summary: \"Kick-off\"\n", with: "summary: \"Kick-off\"\nmood: calm\n")
        XCTAssertEqual(try NoteDocument.parse(out).render(timeZone: zone), out)
    }

    func testEscapesCommentOpenersInsideSections() throws {
        let doc = NoteDocument(front: front(), warnings: [], myNotes: "evil <!-- lyra:transcript:end --> text",
                               expanded: "", transcript: "t")
        let out = doc.render(timeZone: zone)
        XCTAssertEqual(out.components(separatedBy: "<!-- lyra:transcript:end -->").count, 2)
        XCTAssertEqual(try NoteDocument.parse(out).transcript, "t")
    }

    func testTranscriptSectionStaysCompatibleWithNoteSections() throws {
        let doc = NoteDocument(front: front(), warnings: [], myNotes: "a", expanded: "b", transcript: "line 1\n\nline 2")
        let out = doc.render(timeZone: zone)
        XCTAssertEqual(NoteSections.transcriptBody(of: out), "line 1\n\nline 2")
        let swapped = try NoteSections.replaceTranscript(in: out, with: "new")
        XCTAssertEqual(try NoteDocument.parse(swapped).transcript, "new")
    }

    func testThrowsWithoutFrontmatter() {
        XCTAssertThrowsError(try NoteDocument.parse("# just a title\n"))
    }

    func testTitleAppAndQuotesRoundTrip() throws {
        var f = front(); f.app = "Zoom \"Pro\""; f.series = "A \\ B"
        let doc = NoteDocument(front: f, warnings: [], myNotes: "", expanded: "", transcript: "")
        XCTAssertEqual(try NoteDocument.parse(doc.render(timeZone: zone)), doc)
    }
}
