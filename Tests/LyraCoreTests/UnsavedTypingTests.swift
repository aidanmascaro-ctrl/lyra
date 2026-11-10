import XCTest
@testable import LyraCore

/// Typing that hit a conflict as Aidan left the page is kept beside the recording and offered again next time.
final class UnsavedTypingTests: XCTestCase {
    private var vault: URL!
    private var folder: URL!
    private var index: NoteIndex!
    private var url: URL!
    private let id = UUID()

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnsavedTypingTests-\(UUID().uuidString)")
        vault = root.appendingPathComponent("vault")
        folder = root.appendingPathComponent("rec")
        let meetings = vault.appendingPathComponent("Meetings")
        for dir in [meetings, folder!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
        let front = NoteFrontmatter(lyraID: id, title: "Chat", date: Date(timeIntervalSince1970: 1_800_000_000), app: "Zoom",
                                    durationMin: 5, recordings: folder)
        url = meetings.appendingPathComponent("Chat.md")
        try NoteDocument(front: front, warnings: [], myNotes: "- mine", expanded: "", transcript: "").render()
            .write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault.deletingLastPathComponent()) }

    private func blocks(_ md: String) -> [NoteBlock] { NoteMarkdown.parse(md) }

    func testNothingSavedLoadsEmpty() {
        XCTAssertTrue(UnsavedTyping.load(from: folder).isEmpty)
    }

    func testSaveLoadAndClearOneSection() throws {
        try UnsavedTyping.save([.myNotes: blocks("- typed"), .expanded: blocks("- other")], in: folder)
        XCTAssertEqual(UnsavedTyping.load(from: folder)[.myNotes], blocks("- typed"))
        XCTAssertEqual(UnsavedTyping.load(from: folder)[.expanded], blocks("- other"))
        try UnsavedTyping.clear(.myNotes, in: folder)
        XCTAssertNil(UnsavedTyping.load(from: folder)[.myNotes])
        XCTAssertEqual(UnsavedTyping.load(from: folder)[.expanded], blocks("- other"))
        try UnsavedTyping.clear(.expanded, in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(UnsavedTyping.fileName).path))
    }

    /// The whole flow: the last save on leaving the page conflicts, the typing is kept, and reopening asks again.
    func testLeavingWithAConflictKeepsTheTypingForNextTime() throws {
        var sync = NoteSync(loaded: try index.load(id, hint: url))
        var doc = try index.load(id, hint: url).document
        doc.myNotes = "- from Obsidian"
        try doc.render().write(to: url, atomically: true, encoding: .utf8)  // the watcher hasn't seen it yet

        _ = try sync.edited(blocks("- mine\n- typed on the way out"), in: .myNotes, index: index)
        XCTAssertNotNil(sync.conflicts[.myNotes])
        try UnsavedTyping.save(sync.conflicts.mapValues(\.mine), in: folder)

        var reopened = NoteSync(loaded: try index.load(id, hint: url))
        for (section, mine) in UnsavedTyping.load(from: folder) { reopened.restoreConflict(section, mine: mine) }
        XCTAssertEqual(reopened.conflicts[.myNotes]?.mine, blocks("- mine\n- typed on the way out"))
        XCTAssertEqual(try reopened.edited(blocks("- something else"), in: .myNotes, index: index), [],
                       "nothing is written while the conflict waits")
        XCTAssertEqual(try index.load(id, hint: url).document.myNotes, "- from Obsidian")

        _ = try reopened.keepMine(.myNotes, index: index)
        XCTAssertEqual(try index.load(id, hint: url).document.myNotes, "- something else")
    }
}
