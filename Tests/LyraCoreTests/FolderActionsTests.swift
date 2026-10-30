import XCTest
@testable import LyraCore

final class FolderActionsTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var index: NoteIndex!
    private var folders: MeetingFolders!
    private var trashed: [URL] = []
    private let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 27; c.hour = 4; c.minute = 5
        return Calendar.current.date(from: c)!
    }()
    private let prefix = "2026-10-27 0405 — "

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("FolderActionsTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
        folders = MeetingFolders(index: index)
        trashed = []
        _ = try folders.create("Clients")
        _ = try folders.create("Content")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    /// A stand-in for the Trash inside the test's own temp dir, so nothing real is ever moved.
    private lazy var fakeTrash: (URL) throws -> Void = { [self] url in
        let bin = vault.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        trashed.append(url)
    }

    private func note(_ title: String, in folder: String? = nil, series: String? = nil) throws -> LoadedNote {
        let front = NoteFrontmatter(lyraID: UUID(), title: title, date: date, app: "Zoom", durationMin: 5,
                                    recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true), series: series,
                                    summary: "Talked \(title)")
        let doc = NoteDocument(front: front, warnings: [], myNotes: "- mine", expanded: "", transcript: "")
        let dir = folder.map { meetings.appendingPathComponent($0) } ?? meetings!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(prefix + title + ".md")
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
        return try index.load(front.lyraID, hint: url)
    }

    private func parent(_ note: LoadedNote) -> String { note.url.deletingLastPathComponent().lastPathComponent }

    private func page(_ series: String) throws -> String {
        try String(contentsOf: meetings.appendingPathComponent("\(series)/\(series).md"), encoding: .utf8)
    }

    // MARK: Move

    func testMoveIntoAFolderKeepsTheNameAndTheNote() throws {
        let loaded = try note("Workshop")
        let outcome = try FolderActions.move(loaded, to: "Clients", index: index)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertEqual(parent(outcome.note), "Clients")
        XCTAssertEqual(outcome.note.url.lastPathComponent, loaded.url.lastPathComponent)
        XCTAssertEqual(outcome.note.document, loaded.document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: loaded.url.path))
    }

    func testMoveBetweenFolders() throws {
        let outcome = try FolderActions.move(try note("Workshop", in: "Clients"), to: "Content", index: index)
        XCTAssertEqual(parent(outcome.note), "Content")
        XCTAssertEqual(folders.folder(of: outcome.note.url), "Content")
    }

    func testMoveOutGoesBackToTheSeriesFolder() throws {
        let outcome = try FolderActions.move(try note("Workshop", in: "Clients", series: "Elm Park"), to: nil, index: index)
        XCTAssertEqual(parent(outcome.note), "Elm Park")
        XCTAssertEqual(outcome.note.document.front.series, "Elm Park")
    }

    func testMoveOutWithoutASeriesGoesToMeetings() throws {
        let outcome = try FolderActions.move(try note("Workshop", in: "Clients"), to: nil, index: index)
        XCTAssertEqual(outcome.note.url.deletingLastPathComponent().standardizedFileURL, meetings.standardizedFileURL)
    }

    func testMoveToWhereItAlreadyIsChangesNothing() throws {
        let loaded = try note("Workshop", in: "Clients")
        XCTAssertEqual(try FolderActions.move(loaded, to: "Clients", index: index).note.url, loaded.url)
        let unfiled = try note("Solo")
        XCTAssertEqual(try FolderActions.move(unfiled, to: nil, index: index).note.url, unfiled.url)
    }

    func testMoveIntoAMissingFolderIsRefused() throws {
        let loaded = try note("Workshop", in: "Elm Park")
        XCTAssertThrowsError(try FolderActions.move(loaded, to: "Elm Park", index: index)) {
            XCTAssertEqual($0 as? MeetingFoldersError, .missingFolder("Elm Park"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.url.path))
    }

    func testNameClashAddsANumberAndRewritesLinks() throws {
        _ = try note("Workshop", in: "Clients")
        let loaded = try note("Workshop")
        let linker = vault.appendingPathComponent("Daily.md")
        try "See [[\(prefix)Workshop]] and [[\(prefix)Workshop|that]].".write(to: linker, atomically: true, encoding: .utf8)
        let outcome = try FolderActions.move(loaded, to: "Clients", index: index)
        XCTAssertEqual(outcome.note.url.lastPathComponent, prefix + "Workshop (2).md")
        // Both files had the old name only by folder; the moved one's links now point at its new name.
        XCTAssertEqual(try String(contentsOf: linker, encoding: .utf8),
                       "See [[\(prefix)Workshop (2)]] and [[\(prefix)Workshop (2)|that]].")
    }

    func testSeriesThatCameOnlyFromTheFolderIsWrittenDown() throws {
        let loaded = try note("Workshop", in: "Elm Park")   // no series: line, the folder makes it a series
        XCTAssertNil(loaded.document.front.series)
        let outcome = try FolderActions.move(loaded, to: "Clients", index: index)
        XCTAssertEqual(outcome.note.document.front.series, "Elm Park")
        XCTAssertEqual(outcome.note.document.myNotes, "- mine")
        XCTAssertEqual(SeriesActions.currentSeries(of: outcome.note, index: index), "Elm Park")
    }

    func testSeriesPageStillLinksTheFiledMeeting() throws {
        let loaded = try note("Workshop", series: "Elm Park")
        let joined = try SeriesActions.move(loaded, to: "Elm Park", index: index).note
        _ = try note("Other", series: "Elm Park")
        let outcome = try FolderActions.move(joined, to: "Clients", index: index)
        XCTAssertEqual(outcome.problems, [])
        let text = try page("Elm Park")
        XCTAssertTrue(text.contains("[[\(prefix)Workshop|Workshop]]"))
        XCTAssertTrue(text.contains("[[\(prefix)Other|Other]]"))
    }

    // MARK: Remove

    func testRemoveMovesNotesOutAndTrashesTheEmptyFolder() throws {
        let a = try note("A", in: "Clients", series: "Elm Park")
        let b = try note("B", in: "Clients")
        let problems = try FolderActions.remove("Clients", index: index, trash: fakeTrash)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["Clients"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetings.appendingPathComponent("Clients").path))
        XCTAssertEqual(parent(try index.load(a.document.front.lyraID, hint: nil)), "Elm Park")
        XCTAssertEqual(try index.load(b.document.front.lyraID, hint: nil).url.deletingLastPathComponent().standardizedFileURL,
                       meetings.standardizedFileURL)
        XCTAssertEqual(folders.all().map(\.name), ["Content"])
    }

    func testAForeignFileKeepsTheFolderAndSaysSo() throws {
        let a = try note("A", in: "Clients")
        let own = meetings.appendingPathComponent("Clients/My own thoughts.md")
        try "hand written".write(to: own, atomically: true, encoding: .utf8)
        let problems = try FolderActions.remove("Clients", index: index, trash: fakeTrash)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("My own thoughts.md"))
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(try String(contentsOf: own, encoding: .utf8), "hand written")
        XCTAssertNotEqual(parent(try index.load(a.document.front.lyraID, hint: nil)), "Clients")
    }

    func testAFolderLyraCantLookInsideIsNotTrashed() throws {
        let folder = meetings.appendingPathComponent("Clients")
        // Write and search but no read: the marker is still found, but the folder can't be listed.
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let problems = try FolderActions.remove("Clients", index: index, trash: fakeTrash)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems.first?.contains("“Clients”") == true, "\(problems)")
        XCTAssertTrue(problems.first?.contains("couldn't look inside") == true, "\(problems)")
    }

    func testRemovingAMissingFolderIsRefused() {
        XCTAssertThrowsError(try FolderActions.remove("Nope", index: index, trash: fakeTrash)) {
            XCTAssertEqual($0 as? MeetingFoldersError, .missingFolder("Nope"))
        }
    }

    func testFolderCodeNeverDeletesUserContent() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/LyraCore/Folders").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("removeItem"), file.lastPathComponent)
        }
    }
}
