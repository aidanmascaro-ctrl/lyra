import XCTest
@testable import LyraCore

final class NoteSyncTests: XCTestCase {
    private var vault: URL!
    private var index: NoteIndex!
    private var url: URL!
    private let id = UUID()

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("NoteSyncTests-\(UUID().uuidString)")
        let meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
        let front = NoteFrontmatter(lyraID: id, title: "Chat", date: Date(timeIntervalSince1970: 1_800_000_000), app: "Zoom",
                                    durationMin: 5, recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true))
        url = meetings.appendingPathComponent("Chat.md")
        try NoteDocument(front: front, warnings: [], myNotes: "- mine", expanded: "- mine", transcript: "").render()
            .write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    private func blocks(_ md: String) -> [NoteBlock] { NoteMarkdown.parse(md) }
    private func disk() throws -> NoteDocument { try index.load(id, hint: url).document }

    /// Obsidian (or the after-meeting step) writes the file.
    private func writeElsewhere(_ change: (inout NoteDocument) -> Void) throws -> LoadedNote {
        var doc = try disk()
        change(&doc)
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
        return try index.load(id, hint: url)
    }

    private func start() throws -> NoteSync { NoteSync(loaded: try index.load(id, hint: url)) }

    func testOwnSaveIsNotAnOutsideChange() throws {
        var sync = try start()
        XCTAssertEqual(try sync.edited(blocks("- mine\n- more"), in: .myNotes, index: index), [])
        XCTAssertEqual(sync.diskChanged(try index.load(id, hint: url)), [])
    }

    func testOutsideChangeWithNoUnsentEditsIsPushedAndAccepted() throws {
        var sync = try start()
        let changed = try writeElsewhere { $0.myNotes = "- from Obsidian" }
        XCTAssertEqual(sync.diskChanged(changed), [.push(.myNotes, blocks("- from Obsidian"))])
        sync.ack(.myNotes, accepted: true)
        XCTAssertNil(sync.conflict)
        _ = try sync.edited(blocks("- from Obsidian\n- typed after"), in: .myNotes, index: index)
        XCTAssertEqual(try disk().myNotes, "- from Obsidian\n- typed after")
    }

    func testOutsideChangeWithUnsentEditsIsAConflictAndNothingIsWritten() throws {
        var sync = try start()
        let changed = try writeElsewhere { $0.myNotes = "- from Obsidian" }
        _ = sync.diskChanged(changed)
        sync.ack(.myNotes, accepted: false)  // the editor had unsent typing
        XCTAssertEqual(sync.conflict?.section, .myNotes)
        XCTAssertEqual(try sync.edited(blocks("- mine typed"), in: .myNotes, index: index), [])
        XCTAssertEqual(try disk().myNotes, "- from Obsidian")
        XCTAssertEqual(sync.conflict?.mine, blocks("- mine typed"))
    }

    func testReloadForcesDiskEvenOverLaterTyping() throws {
        var sync = try start()
        _ = sync.diskChanged(try writeElsewhere { $0.myNotes = "- from Obsidian" })
        sync.ack(.myNotes, accepted: false)
        _ = try sync.edited(blocks("- typed after the banner"), in: .myNotes, index: index)
        XCTAssertEqual(sync.reload(), [.forcePush(.myNotes, blocks("- from Obsidian"))])
        XCTAssertNil(sync.conflict)
        XCTAssertEqual(try disk().myNotes, "- from Obsidian")
        _ = try sync.edited(blocks("- from Obsidian\n- next"), in: .myNotes, index: index)
        XCTAssertEqual(try disk().myNotes, "- from Obsidian\n- next")
    }

    func testKeepMineWritesMineAndKeepsTheRest() throws {
        var sync = try start()
        _ = sync.diskChanged(try writeElsewhere { $0.myNotes = "- from Obsidian"; $0.expanded = "- other" })
        sync.ack(.myNotes, accepted: false)
        sync.ack(.expanded, accepted: true)
        _ = try sync.edited(blocks("- mine typed"), in: .myNotes, index: index)
        XCTAssertEqual(try sync.keepMine(index: index), [])
        XCTAssertNil(sync.conflict)
        XCTAssertEqual(try disk().myNotes, "- mine typed")
        XCTAssertEqual(try disk().expanded, "- other")
    }

    func testSaveRaisesConflictWhenTheWatcherHasNotSeenTheChangeYet() throws {
        var sync = try start()
        _ = try writeElsewhere { $0.myNotes = "- from Obsidian" }
        XCTAssertEqual(try sync.edited(blocks("- mine typed"), in: .myNotes, index: index), [])
        XCTAssertEqual(sync.conflict?.section, .myNotes)
        XCTAssertEqual(try disk().myNotes, "- from Obsidian")
    }

    func testStreamedExpandedWhileTypingMyNotesKeepsBoth() throws {
        var sync = try start()
        _ = try writeElsewhere { $0.expanded = "- mine\n  - <span class=\"lyra\">streamed</span>" }
        // Typing saves before the watcher reports the stream: merged, and the new Expanded goes to its editor.
        let effects = try sync.edited(blocks("- mine\n- typed"), in: .myNotes, index: index)
        XCTAssertEqual(effects, [.push(.expanded, blocks("- mine\n  - <span class=\"lyra\">streamed</span>"))])
        sync.ack(.expanded, accepted: true)
        XCTAssertEqual(sync.diskChanged(try index.load(id, hint: url)), [])  // already seen
        // Editing Expanded later starts from the streamed version, so nothing streamed is lost.
        _ = try sync.edited(blocks("- mine\n  - <span class=\"lyra\">streamed</span>\n- my point"), in: .expanded, index: index)
        XCTAssertEqual(try disk().myNotes, "- mine\n- typed")
        XCTAssertEqual(try disk().expanded, "- mine\n  - <span class=\"lyra\">streamed</span>\n- my point")
    }

    func testAcceptedNoteFromElsewherePushesChangedSections() throws {
        var sync = try start()
        let renamed = try writeElsewhere { $0.front.title = "New"; $0.expanded = "- grey added" }
        XCTAssertEqual(sync.accept(renamed), [.push(.expanded, blocks("- grey added"))])
        XCTAssertEqual(sync.loaded.document.front.title, "New")
    }
}
