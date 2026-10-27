import XCTest
@testable import LyraCore

final class NoteIndexTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var index: NoteIndex!
    // 2026-10-27 04:05 in the current time zone, so file names match what NoteIndex derives.
    private let noteDate: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 27; c.hour = 4; c.minute = 5
        return Calendar.current.date(from: c)!
    }()
    private let prefix = "2026-10-27 0405 — "

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("NoteIndexTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func makeDocument(id: UUID = UUID(), title: String, series: String? = nil) -> NoteDocument {
        let front = NoteFrontmatter(lyraID: id, title: title, date: noteDate, app: "Zoom", durationMin: 10,
                                    recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true), series: series)
        return NoteDocument(front: front, warnings: [], myNotes: "typed by Aidan", expanded: "", transcript: "")
    }

    @discardableResult
    private func writeNote(_ doc: NoteDocument, name: String, in dir: URL? = nil) throws -> URL {
        let folder = dir ?? meetings!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".md")
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testFindsMovedNoteByLyraID() throws {
        let doc = makeDocument(title: "Chat")
        let oldURL = try writeNote(doc, name: prefix + "Chat")
        XCTAssertEqual(index.find(doc.front.lyraID, hint: oldURL), oldURL)

        let newDir = meetings.appendingPathComponent("Some Series")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newURL = newDir.appendingPathComponent("Renamed by hand.md")
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        XCTAssertEqual(index.find(doc.front.lyraID, hint: oldURL)?.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(try index.load(doc.front.lyraID, hint: nil).document, doc)
        XCTAssertNil(index.find(UUID(), hint: nil))
        XCTAssertThrowsError(try index.load(UUID(), hint: nil)) { error in
            XCTAssertEqual(error.localizedDescription, "Lyra couldn't find this meeting's note in the Meetings folder.")
        }
    }

    func testSaveWritesAndReturnsFreshFingerprint() throws {
        let doc = makeDocument(title: "Chat")
        try writeNote(doc, name: prefix + "Chat")
        let loaded = try index.load(doc.front.lyraID, hint: nil)
        var edited = loaded.document
        edited.myNotes = "more words"
        let saved = try index.save(edited, over: loaded)
        XCTAssertNotEqual(saved.fingerprint, loaded.fingerprint)
        XCTAssertTrue(try read(saved.url).contains("more words"))
        XCTAssertEqual(try index.save(edited, over: saved).fingerprint, saved.fingerprint)
    }

    func testSaveRefusesWhenFileChangedOnDisk() throws {
        let doc = makeDocument(title: "Chat")
        let url = try writeNote(doc, name: prefix + "Chat")
        let loaded = try index.load(doc.front.lyraID, hint: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\nAidan typed this in Obsidian\n".utf8)); try handle.close()

        var edited = loaded.document
        edited.myNotes = "Lyra's version"
        XCTAssertThrowsError(try index.save(edited, over: loaded)) { error in
            XCTAssertEqual(error as? NoteIndexError, .changedOnDisk(url))
            XCTAssertEqual(error.localizedDescription,
                           "This note was changed in Obsidian since Lyra opened it, so Lyra didn't save over it.")
        }
        let onDisk = try read(url)
        XCTAssertTrue(onDisk.contains("Aidan typed this in Obsidian"))
        XCTAssertFalse(onDisk.contains("Lyra's version"))
    }

    func testRenameKeepsUniqueLegalNameAndRewritesLinks() throws {
        let doc = makeDocument(title: "Google Chrome")
        let url = try writeNote(doc, name: prefix + "Google Chrome")
        let linking = vault.appendingPathComponent("Clients/Acme.md")
        try FileManager.default.createDirectory(at: linking.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldName = prefix + "Google Chrome"
        try """
        See [[\(oldName)]] and [[\(oldName)|the call]] and [[\(oldName)#Transcript]].
        Not this: [[\(oldName) extra]] or [[google chrome]].
        """.write(to: linking, atomically: true, encoding: .utf8)
        let hidden = vault.appendingPathComponent(".obsidian/cache.md")
        try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[[\(oldName)]]".write(to: hidden, atomically: true, encoding: .utf8)

        let loaded = try index.load(doc.front.lyraID, hint: url)
        let title = "Workshop 2: Strategy / Q&A"
        let moved = try index.relocate(loaded, title: title, series: "Elm Park Startup Series")

        let newBase = prefix + MeetingPaths.sanitise(title)
        XCTAssertEqual(moved.url.lastPathComponent, newBase + ".md")
        XCTAssertEqual(moved.url.deletingLastPathComponent().lastPathComponent, "Elm Park Startup Series")
        XCTAssertFalse(moved.url.lastPathComponent.contains(":") || moved.url.lastPathComponent.contains("/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try index.load(doc.front.lyraID, hint: nil).url.standardizedFileURL, moved.url.standardizedFileURL)

        let links = try read(linking)
        XCTAssertTrue(links.contains("[[\(newBase)]]"))
        XCTAssertTrue(links.contains("[[\(newBase)|the call]]"))
        XCTAssertTrue(links.contains("[[\(newBase)#Transcript]]"))
        XCTAssertTrue(links.contains("[[\(oldName) extra]]"))
        XCTAssertTrue(links.contains("[[google chrome]]"))
        XCTAssertEqual(try read(hidden), "[[\(oldName)]]")

        // A second note with the same title and series gets " (2)".
        let other = makeDocument(title: "Other")
        let otherURL = try writeNote(other, name: prefix + "Other")
        let second = try index.relocate(try index.load(other.front.lyraID, hint: otherURL),
                                        title: title, series: "Elm Park Startup Series")
        XCTAssertEqual(second.url.lastPathComponent, newBase + " (2).md")
    }

    func testRelocateToCurrentPathIsANoOp() throws {
        let doc = makeDocument(title: "Chat", series: "Series A")
        let url = try writeNote(doc, name: prefix + "Chat", in: meetings.appendingPathComponent("Series A"))
        let loaded = try index.load(doc.front.lyraID, hint: url)
        let again = try index.relocate(loaded, title: "Chat", series: "Series A")
        XCTAssertEqual(again.url, loaded.url)
        XCTAssertEqual(again.fingerprint, loaded.fingerprint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRelocateReportsLinkFilesItCouldNotUpdate() throws {
        let doc = makeDocument(title: "Chat")
        let url = try writeNote(doc, name: prefix + "Chat")
        let bad = vault.appendingPathComponent("Binary.md")
        var bytes = Data("[[\(prefix)Chat]] ".utf8); bytes.append(contentsOf: [0xFF, 0xFE, 0xFD])
        try bytes.write(to: bad)
        let good = vault.appendingPathComponent("Good.md")
        try "[[\(prefix)Chat]]".write(to: good, atomically: true, encoding: .utf8)

        let result = try index.relocateReportingSkips(try index.load(doc.front.lyraID, hint: url), title: "New", series: nil)
        XCTAssertEqual(result.skippedLinkFiles.map(\.lastPathComponent), ["Binary.md"])
        XCTAssertEqual(try read(good), "[[\(prefix)New]]")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.note.url.path))
    }

    func testRenameSeriesFolderUpdatesNotes() throws {
        let dir = meetings.appendingPathComponent("Old Series")
        let doc = makeDocument(title: "Chat", series: "Old Series")
        try writeNote(doc, name: prefix + "Chat", in: dir)
        let page = dir.appendingPathComponent("Old Series.md")
        try "Series page".write(to: page, atomically: true, encoding: .utf8)
        let client = vault.appendingPathComponent("Client.md")
        try "Part of [[Old Series]] and [[Old Series|the series]].".write(to: client, atomically: true, encoding: .utf8)

        try index.renameSeriesFolder(from: "Old Series", to: "New Series")

        let newDir = meetings.appendingPathComponent("New Series")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(try index.load(doc.front.lyraID, hint: nil).document.front.series, "New Series")
        XCTAssertEqual(try index.load(doc.front.lyraID, hint: nil).url.deletingLastPathComponent().lastPathComponent, "New Series")
        XCTAssertEqual(try read(newDir.appendingPathComponent("New Series.md")), "Series page")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("Old Series.md").path))
        XCTAssertEqual(try read(client), "Part of [[New Series]] and [[New Series|the series]].")
    }

    func testAllNotesListsOnlyLyraNotes() throws {
        let a = makeDocument(title: "A"), b = makeDocument(title: "B", series: "S")
        try writeNote(a, name: prefix + "A")
        try writeNote(b, name: prefix + "B", in: meetings.appendingPathComponent("S"))
        try "just a page".write(to: meetings.appendingPathComponent("Plain.md"), atomically: true, encoding: .utf8)
        let ids = Set(index.allNotes().map(\.document.front.lyraID))
        XCTAssertEqual(ids, [a.front.lyraID, b.front.lyraID])
    }
}

extension NoteIndexTests {
    func testAllNotesSkipsSeriesPages() throws {
        let dir = meetings.appendingPathComponent("Weekly")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nlyra_series: true\n---\n# Weekly\n\n".write(to: dir.appendingPathComponent("Weekly.md"), atomically: true, encoding: .utf8)
        let doc = makeDocument(title: "Real")
        try writeNote(doc, name: prefix + "Real", in: dir)
        XCTAssertEqual(index.allNotes().map(\.document.front.lyraID), [doc.front.lyraID])
    }
}

// MARK: Concurrent writers (final fix wave)

/// Collects errors thrown on other threads.
private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func add(_ error: Error) { lock.withLock { errors.append(error) } }
    var all: [Error] { lock.withLock { errors } }
}

extension NoteIndexTests {
    private static let rounds = 60

    /// The editor saves My notes on the main actor while the after-meeting step streams Expanded in the background:
    /// every change from both survives.
    func testConcurrentWritersToDifferentSectionsBothSurvive() throws {
        let doc = makeDocument(title: "Chat")
        let url = try writeNote(doc, name: prefix + "Chat")
        let start = try index.load(doc.front.lyraID, hint: url)
        let (index, failures, rounds) = (index!, Failures(), Self.rounds)
        DispatchQueue.concurrentPerform(iterations: 2) { writer in
            var current = start
            var lines: [String] = []
            for n in 1...rounds {
                lines.append("- \(writer == 0 ? "typed" : "grey") \(n)")
                let text = lines.joined(separator: "\n")
                do {
                    current = try index.update(current) { if writer == 0 { $0.myNotes = text } else { $0.expanded = text } }
                } catch { failures.add(error) }
            }
        }
        XCTAssertTrue(failures.all.isEmpty, "\(failures.all)")
        let final = try index.load(doc.front.lyraID, hint: url).document
        XCTAssertEqual(final.myNotes, (1...rounds).map { "- typed \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(final.expanded, (1...rounds).map { "- grey \($0)" }.joined(separator: "\n"))
    }

    /// A save racing a rename must never bring the note back at its old path: one file per lyra_id, always.
    func testSaveRacingRelocateNeverLeavesTwoCopies() throws {
        let doc = makeDocument(title: "Chat")
        let url = try writeNote(doc, name: prefix + "Chat")
        let start = try index.load(doc.front.lyraID, hint: url)
        let (index, failures, rounds) = (index!, Failures(), Self.rounds)
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            var current = start
            for n in 1...rounds {
                do {
                    if worker == 0 {
                        current = try index.relocate(current, title: "Chat \(n)", series: nil)
                    } else {
                        current = try index.update(current) { $0.myNotes = "typed \(n)" }
                    }
                } catch { failures.add(error) }
            }
        }
        XCTAssertTrue(failures.all.isEmpty, "\(failures.all)")
        let copies = index.allNotes().filter { $0.document.front.lyraID == doc.front.lyraID }
        XCTAssertEqual(copies.count, 1, copies.map(\.url.lastPathComponent).description)
        XCTAssertEqual(copies.first?.document.myNotes, "typed \(rounds)")
    }

    func testSaveAfterNoteWasMovedAwayThrowsAndRecreatesNothing() throws {
        let doc = makeDocument(title: "Chat")
        let url = try writeNote(doc, name: prefix + "Chat")
        let loaded = try index.load(doc.front.lyraID, hint: url)
        let trash = vault.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("Chat.md"))

        var edited = loaded.document
        edited.myNotes = "typed after the move"
        XCTAssertThrowsError(try index.save(edited, over: loaded))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The write itself never creates a file it was meant to replace (it vanished between the check and the swap).
    func testWriteAtomicallyNeverCreatesAMissingFile() throws {
        let missing = meetings.appendingPathComponent("Gone.md")
        XCTAssertThrowsError(try NoteIndex.writeAtomically(Data("hello".utf8), to: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: meetings.path)
        XCTAssertEqual(leftovers, [])  // no temp file left behind

        try NoteIndex.writeAtomically(Data("hello".utf8), to: missing, mayCreate: true)
        XCTAssertEqual(try read(missing), "hello")
        try NoteIndex.writeAtomically(Data("again".utf8), to: missing)
        XCTAssertEqual(try read(missing), "again")
    }
}
