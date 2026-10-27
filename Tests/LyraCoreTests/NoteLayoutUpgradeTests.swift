import XCTest
@testable import LyraCore

/// Notes written before headings nested, the transcript folded and the jump line existed are brought over once,
/// keeping every word; a note already in the current layout is left alone.
final class NoteLayoutUpgradeTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var index: NoteIndex!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("NoteLayoutUpgradeTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private let oldLayout = """
    ---
    lyra_id: 11111111-2222-3333-4444-555555555555
    date: 2027-01-15T16:00:00+08:00
    app: "Zoom"
    duration_min: 52
    recordings: "file:///x/"
    tags: [meeting]
    links: []
    ---
    # Weekly sync

    A line Aidan typed under the title.

    ## My notes
    <!-- lyra:mynotes:start -->
    - pricing
    ## my own heading
    <!-- lyra:mynotes:end -->

    ## Expanded
    <!-- lyra:expanded:start -->
    ## <span class="lyra">Decisions</span>
    - <span class="lyra">Raise the price.</span>
    <!-- lyra:expanded:end -->

    ## Transcript
    <!-- lyra:transcript:start -->
    **Aidan** [00:00:01] hello

    **Sam** [00:00:03] hi
    <!-- lyra:transcript:end -->

    """

    func testOldLayoutIsRewrittenOnceKeepingEveryWord() throws {
        let url = meetings.appendingPathComponent("2027-01-15 1600 — Weekly sync.md")
        try oldLayout.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(NoteLayoutUpgrade.run(index: index), [])

        let text = try String(contentsOf: url, encoding: .utf8)
        for expected in ["[[#My notes|My notes]] · [[#Expanded|Expanded]] · [[#Transcript|Transcript]]",
                         "A line Aidan typed under the title.", "- pricing\n#### my own heading",
                         "### <span class=\"lyra\">Decisions</span>\n- <span class=\"lyra\">Raise the price.</span>",
                         "> [!quote]- Full transcript\n> **Aidan** [00:00:01] hello\n>\n> **Sam** [00:00:03] hi"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        let doc = try NoteDocument.parse(text)
        XCTAssertEqual(doc.transcript, "**Aidan** [00:00:01] hello\n\n**Sam** [00:00:03] hi")
        XCTAssertEqual(doc.myNotes, "- pricing\n#### my own heading")

        XCTAssertEqual(NoteLayoutUpgrade.run(index: index), [])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "a second run changes nothing")
    }

    func testCurrentLayoutIsLeftAlone() throws {
        let url = meetings.appendingPathComponent("2027-01-15 1600 — Weekly sync.md")
        try oldLayout.write(to: url, atomically: true, encoding: .utf8)
        _ = NoteLayoutUpgrade.run(index: index)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(NoteLayoutUpgrade.run(index: index), [])
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testFilesWithoutALyraHeaderAreSkipped() throws {
        let url = meetings.appendingPathComponent("Series page.md")
        try "---\nlyra_series: true\n---\n# Weekly\n\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(NoteLayoutUpgrade.run(index: index), [])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "---\nlyra_series: true\n---\n# Weekly\n\n")
    }
}
