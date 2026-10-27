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

    /// Effects without push ids, for comparing.
    private func plain(_ effects: [NoteSync.Effect]) -> [String] {
        effects.map {
            switch $0 {
            case .push(let s, let b, _): "push \(s) \(NoteMarkdown.render(b))"
            case .forcePush(let s, let b): "force \(s) \(NoteMarkdown.render(b))"
            }
        }
    }

    /// The id of the only push in `effects`.
    private func pushID(_ effects: [NoteSync.Effect]) -> Int {
        effects.compactMap { if case .push(_, _, let id) = $0 { id } else { nil } }.first ?? -1
    }

    func testOwnSaveIsNotAnOutsideChange() throws {
        var sync = try start()
        XCTAssertEqual(try sync.edited(blocks("- mine\n- more"), in: .myNotes, index: index), [])
        XCTAssertEqual(sync.diskChanged(try index.load(id, hint: url)), [])
    }

    func testOutsideChangeWithNoUnsentEditsIsPushedAndAccepted() throws {
        var sync = try start()
        let changed = try writeElsewhere { $0.myNotes = "- from Obsidian" }
        let effects = sync.diskChanged(changed)
        XCTAssertEqual(plain(effects), ["push myNotes - from Obsidian"])
        sync.ack(.myNotes, id: pushID(effects), accepted: true)
        XCTAssertTrue(sync.conflicts.isEmpty)
        _ = try sync.edited(blocks("- from Obsidian\n- typed after"), in: .myNotes, index: index)
        XCTAssertEqual(try disk().myNotes, "- from Obsidian\n- typed after")
    }

    func testOutsideChangeWithUnsentEditsIsAConflictAndNothingIsWritten() throws {
        var sync = try start()
        let changed = try writeElsewhere { $0.myNotes = "- from Obsidian" }
        let effects = sync.diskChanged(changed)
        sync.ack(.myNotes, id: pushID(effects), accepted: false)  // the editor had unsent typing
        XCTAssertNotNil(sync.conflicts[.myNotes])
        XCTAssertEqual(try sync.edited(blocks("- mine typed"), in: .myNotes, index: index), [])
        XCTAssertEqual(try disk().myNotes, "- from Obsidian")
        XCTAssertEqual(sync.conflicts[.myNotes]?.mine, blocks("- mine typed"))
    }

    func testReloadForcesDiskEvenOverLaterTyping() throws {
        var sync = try start()
        let effects = sync.diskChanged(try writeElsewhere { $0.myNotes = "- from Obsidian" })
        sync.ack(.myNotes, id: pushID(effects), accepted: false)
        _ = try sync.edited(blocks("- typed after the banner"), in: .myNotes, index: index)
        XCTAssertEqual(plain(sync.reload(.myNotes)), ["force myNotes - from Obsidian"])
        XCTAssertTrue(sync.conflicts.isEmpty)
        XCTAssertEqual(try disk().myNotes, "- from Obsidian")
        _ = try sync.edited(blocks("- from Obsidian\n- next"), in: .myNotes, index: index)
        XCTAssertEqual(try disk().myNotes, "- from Obsidian\n- next")
    }

    func testKeepMineWritesMineAndKeepsTheRest() throws {
        var sync = try start()
        let effects = sync.diskChanged(try writeElsewhere { $0.myNotes = "- from Obsidian"; $0.expanded = "- other" })
        let ids = effects.compactMap { if case .push(let s, _, let id) = $0 { (s, id) } else { nil } }
        for (section, id) in ids { sync.ack(section, id: id, accepted: section == .expanded) }
        _ = try sync.edited(blocks("- mine typed"), in: .myNotes, index: index)
        XCTAssertEqual(try sync.keepMine(.myNotes, index: index), [])
        XCTAssertTrue(sync.conflicts.isEmpty)
        XCTAssertEqual(try disk().myNotes, "- mine typed")
        XCTAssertEqual(try disk().expanded, "- other")
    }

    func testSaveRaisesConflictWhenTheWatcherHasNotSeenTheChangeYet() throws {
        var sync = try start()
        _ = try writeElsewhere { $0.myNotes = "- from Obsidian" }
        XCTAssertEqual(try sync.edited(blocks("- mine typed"), in: .myNotes, index: index), [])
        XCTAssertNotNil(sync.conflicts[.myNotes])
        XCTAssertEqual(try disk().myNotes, "- from Obsidian")
    }

    func testStreamedExpandedWhileTypingMyNotesKeepsBoth() throws {
        var sync = try start()
        _ = try writeElsewhere { $0.expanded = "- mine\n  - <span class=\"lyra\">streamed</span>" }
        // Typing saves before the watcher reports the stream: merged, and the new Expanded goes to its editor.
        let effects = try sync.edited(blocks("- mine\n- typed"), in: .myNotes, index: index)
        XCTAssertEqual(plain(effects), ["push expanded - mine\n  - <span class=\"lyra\">streamed</span>"])
        sync.ack(.expanded, id: pushID(effects), accepted: true)
        XCTAssertEqual(sync.diskChanged(try index.load(id, hint: url)), [])  // already seen
        // Editing Expanded later starts from the streamed version, so nothing streamed is lost.
        _ = try sync.edited(blocks("- mine\n  - <span class=\"lyra\">streamed</span>\n- my point"), in: .expanded, index: index)
        XCTAssertEqual(try disk().myNotes, "- mine\n- typed")
        XCTAssertEqual(try disk().expanded, "- mine\n  - <span class=\"lyra\">streamed</span>\n- my point")
    }

    func testAcceptedNoteFromElsewherePushesChangedSections() throws {
        var sync = try start()
        let renamed = try writeElsewhere { $0.front.title = "New"; $0.expanded = "- grey added" }
        XCTAssertEqual(plain(sync.accept(renamed)), ["push expanded - grey added"])
        XCTAssertEqual(sync.loaded.document.front.title, "New")
    }

    // MARK: Round 2

    func testSecondSectionConflictWhileTheFirstIsOpen() throws {
        var sync = try start()
        let first = sync.diskChanged(try writeElsewhere { $0.myNotes = "- Obsidian notes" })
        sync.ack(.myNotes, id: pushID(first), accepted: false)
        let second = sync.diskChanged(try writeElsewhere { $0.expanded = "- Obsidian expanded" })
        sync.ack(.expanded, id: pushID(second), accepted: false)  // typing in Expanded too
        XCTAssertEqual(try sync.edited(blocks("- my expanded"), in: .expanded, index: index), [])
        XCTAssertNotNil(sync.conflicts[.myNotes])
        XCTAssertNotNil(sync.conflicts[.expanded])
        XCTAssertEqual(try disk().expanded, "- Obsidian expanded")
        XCTAssertEqual(try disk().myNotes, "- Obsidian notes")
    }

    func testSaveHittingASecondSectionChangeIsItsOwnConflict() throws {
        var sync = try start()
        let first = sync.diskChanged(try writeElsewhere { $0.myNotes = "- Obsidian notes" })
        sync.ack(.myNotes, id: pushID(first), accepted: false)
        _ = try writeElsewhere { $0.expanded = "- Obsidian expanded" }  // the watcher hasn't reported it yet
        _ = try sync.edited(blocks("- my expanded"), in: .expanded, index: index)
        XCTAssertNotNil(sync.conflicts[.expanded])
        XCTAssertNotNil(sync.conflicts[.myNotes])
        XCTAssertEqual(try disk().expanded, "- Obsidian expanded")
    }

    func testEditArrivingBeforeThePushIsAnsweredIsAConflict() throws {
        var sync = try start()
        _ = sync.diskChanged(try writeElsewhere { $0.myNotes = "- from Obsidian" })
        // The editor's debounce fires before it has even seen the push.
        XCTAssertEqual(try sync.edited(blocks("- mine typed"), in: .myNotes, index: index), [])
        XCTAssertNotNil(sync.conflicts[.myNotes])
        XCTAssertEqual(try disk().myNotes, "- from Obsidian")
    }

    func testEditEqualToThePendingPushIsNotAConflict() throws {
        var sync = try start()
        _ = sync.diskChanged(try writeElsewhere { $0.myNotes = "- from Obsidian" })
        _ = try sync.edited(blocks("- from Obsidian"), in: .myNotes, index: index)
        XCTAssertTrue(sync.conflicts.isEmpty)
    }

    func testStaleAnswerDoesNotResolveANewerPush() throws {
        var sync = try start()
        let a = sync.diskChanged(try writeElsewhere { $0.myNotes = "- A" })
        let b = sync.diskChanged(try writeElsewhere { $0.myNotes = "- B" })
        XCTAssertNotEqual(pushID(a), pushID(b))
        sync.ack(.myNotes, id: pushID(a), accepted: true)  // late answer to A
        // B is still unanswered, so typing now must not save over it.
        _ = try sync.edited(blocks("- typed"), in: .myNotes, index: index)
        XCTAssertNotNil(sync.conflicts[.myNotes])
        XCTAssertEqual(try disk().myNotes, "- B")
        sync.ack(.myNotes, id: pushID(b), accepted: false)  // and B's answer changes nothing more
        XCTAssertEqual(sync.conflicts[.myNotes]?.mine, blocks("- typed"))
    }

    func testLyraWriteIsPushedAndAnswered() throws {
        var sync = try start()
        let grey = blocks("- mine\n  - <span class=\"lyra\">added</span>")
        let result = try sync.writeExpanded(grey, index: index)
        XCTAssertTrue(result.written)
        XCTAssertEqual(plain(result.effects), ["push expanded " + NoteMarkdown.render(grey)])
        XCTAssertEqual(try disk().expanded, NoteMarkdown.render(grey))
        XCTAssertEqual(try disk().myNotes, "- mine", "Lyra's writes never touch My notes")
        sync.ack(.expanded, id: pushID(result.effects), accepted: false)  // Aidan was typing
        XCTAssertNotNil(sync.conflicts[.expanded])
    }

    func testLyraWriteWaitsWhileTheSectionIsUnsettled() throws {
        var sync = try start()
        _ = sync.diskChanged(try writeElsewhere { $0.expanded = "- from Obsidian" })
        let result = try sync.writeExpanded(blocks("- claude"), index: index)
        XCTAssertFalse(result.written)
        XCTAssertEqual(try disk().expanded, "- from Obsidian")
    }

    /// Moved in Obsidian with its text unchanged: Lyra follows it to the new path, with nothing to push.
    func testMoveWithUnchangedContentFollowsTheNewPath() throws {
        var sync = try start()
        let folder = url.deletingLastPathComponent().appendingPathComponent("Series", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("Chat.md")
        try FileManager.default.moveItem(at: url, to: moved)

        XCTAssertEqual(sync.diskChanged(try index.load(id, hint: moved)), [])
        XCTAssertEqual(sync.loaded.url.standardizedFileURL, moved.standardizedFileURL)
        // Saves now go to the new path.
        _ = try sync.edited(blocks("- mine\n- more"), in: .myNotes, index: index)
        XCTAssertEqual(try index.load(id, hint: moved).document.myNotes, "- mine\n- more")
        XCTAssertEqual(try index.load(id, hint: moved).url.standardizedFileURL, moved.standardizedFileURL)
    }
}
