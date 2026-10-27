import XCTest
@testable import LyraCore

final class NoteEditsTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var index: NoteIndex!
    private var url: URL!
    private let id = UUID()

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("NoteEditsTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
        let front = NoteFrontmatter(lyraID: id, title: "Chat", date: Date(timeIntervalSince1970: 1_800_000_000), app: "Zoom",
                                    durationMin: 5, recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true))
        let doc = NoteDocument(front: front, warnings: [], myNotes: "- typed", expanded: "- typed", transcript: "**A** [00:00:01] hi")
        url = meetings.appendingPathComponent("Chat.md")
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    private func bullets(_ texts: String...) -> [NoteBlock] {
        texts.map { NoteBlock(kind: .bullet, runs: [InlineRun(text: $0)]) }
    }

    /// Someone else (Obsidian) edits the file.
    private func editOnDisk(_ change: (inout NoteDocument) -> Void) throws {
        var doc = try index.load(id, hint: url).document
        change(&doc)
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
    }

    func testSaveWritesOnlyThatSection() throws {
        let loaded = try index.load(id, hint: url)
        guard case .saved(let saved) = try NoteEdits.save(bullets("typed", "more"), to: .myNotes, over: loaded, index: index)
        else { return XCTFail("expected a save") }
        let disk = try index.load(id, hint: url).document
        XCTAssertEqual(disk.myNotes, "- typed\n- more")
        XCTAssertEqual(disk.expanded, "- typed")
        XCTAssertEqual(disk.transcript, "**A** [00:00:01] hi")
        XCTAssertEqual(saved.fingerprint, try index.load(id, hint: url).fingerprint)
    }

    func testSaveMergesWhenOnlyAnotherSectionChangedOnDisk() throws {
        let loaded = try index.load(id, hint: url)
        try editOnDisk { $0.expanded = "- typed\n  - <span class=\"lyra\">streamed</span>" }
        guard case .saved = try NoteEdits.save(bullets("typed", "more"), to: .myNotes, over: loaded, index: index)
        else { return XCTFail("expected a save") }
        let disk = try index.load(id, hint: url).document
        XCTAssertEqual(disk.myNotes, "- typed\n- more")
        XCTAssertEqual(disk.expanded, "- typed\n  - <span class=\"lyra\">streamed</span>")
    }

    func testSaveReportsConflictWhenSameSectionChangedOnDisk() throws {
        let loaded = try index.load(id, hint: url)
        try editOnDisk { $0.myNotes = "- typed in Obsidian" }
        let before = try String(contentsOf: url, encoding: .utf8)
        guard case .conflict(let disk) = try NoteEdits.save(bullets("typed in Lyra"), to: .myNotes, over: loaded, index: index)
        else { return XCTFail("expected a conflict") }
        XCTAssertEqual(disk.document.myNotes, "- typed in Obsidian")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
    }

    func testKeepMineReplacesOnlyThatSection() throws {
        try editOnDisk { $0.myNotes = "- typed in Obsidian"; $0.expanded = "- other" }
        let disk = try index.load(id, hint: url)
        _ = try NoteEdits.keepMine(bullets("typed in Lyra"), section: .myNotes, over: disk, index: index)
        let doc = try index.load(id, hint: url).document
        XCTAssertEqual(doc.myNotes, "- typed in Lyra")
        XCTAssertEqual(doc.expanded, "- other")
    }

    func testRememberGreyAddsHashesOfClaudesBlocks() throws {
        let folder = vault.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meeting = Meeting(id: id, title: "Chat", appName: "Zoom", startedAt: Date())
        meeting.expandedHashes = ["old"]
        try meeting.save(in: folder)
        let grey = NoteBlock(kind: .paragraph, runs: [InlineRun(text: "answer")], byClaude: true)
        try NoteEdits.rememberGrey([grey] + bullets("mine"), meetingFolder: folder)
        XCTAssertEqual(try Meeting.load(from: folder).expandedHashes, ["old"] + ExpandedMerge.hashes(of: [grey]))
    }

    func testSaveFollowsANoteMovedMeanwhile() throws {
        let loaded = try index.load(id, hint: url)
        let moved = meetings.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: url, to: moved)
        guard case .saved(let saved) = try NoteEdits.save(bullets("typed", "more"), to: .myNotes, over: loaded, index: index)
        else { return XCTFail("expected a save") }
        XCTAssertEqual(saved.url.standardizedFileURL, moved.standardizedFileURL)
        XCTAssertEqual(try index.load(id, hint: moved).document.myNotes, "- typed\n- more")
    }
}
