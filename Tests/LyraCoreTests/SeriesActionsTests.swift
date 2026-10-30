import XCTest
@testable import LyraCore

final class SeriesActionsTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var index: NoteIndex!
    private let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 27; c.hour = 4; c.minute = 5
        return Calendar.current.date(from: c)!
    }()
    private let prefix = "2026-10-27 0405 — "

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("SeriesActionsTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    private func note(_ title: String, series: String? = nil) throws -> LoadedNote {
        let front = NoteFrontmatter(lyraID: UUID(), title: title, date: date, app: "Zoom", durationMin: 5,
                                    recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true), series: series,
                                    summary: "Talked \(title)")
        let doc = NoteDocument(front: front, warnings: [], myNotes: "- mine", expanded: "", transcript: "")
        let folder = series.map { meetings.appendingPathComponent($0) } ?? meetings!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(prefix + title + ".md")
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
        return try index.load(front.lyraID, hint: url)
    }

    private func page(_ series: String) throws -> String {
        try String(contentsOf: meetings.appendingPathComponent("\(series)/\(series).md"), encoding: .utf8)
    }

    func testMoveIntoSeriesFilesTheNoteAndWritesThePage() throws {
        let loaded = try note("Workshop 1")
        let outcome = try SeriesActions.move(loaded, to: "Elm Park", index: index)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertEqual(outcome.note.document.front.series, "Elm Park")
        XCTAssertEqual(outcome.note.url.deletingLastPathComponent().lastPathComponent, "Elm Park")
        XCTAssertEqual(outcome.note.document.myNotes, "- mine")
        XCTAssertTrue(try page("Elm Park").contains("[[\(prefix)Workshop 1|Workshop 1]]"))
    }

    func testMoveOutOfSeriesUpdatesTheOldPage() throws {
        let loaded = try note("Workshop 1", series: "Elm Park")
        _ = try note("Workshop 2", series: "Elm Park")
        try SeriesLibrary.writeSeriesPage(name: "Elm Park", index: index)
        let outcome = try SeriesActions.move(loaded, to: nil, index: index)
        XCTAssertNil(outcome.note.document.front.series)
        XCTAssertEqual(outcome.note.url.deletingLastPathComponent().standardizedFileURL, meetings.standardizedFileURL)
        XCTAssertFalse(try page("Elm Park").contains("Workshop 1"))
        XCTAssertTrue(try page("Elm Park").contains("Workshop 2"))
    }

    func testHandWrittenNoteInTheWayIsReportedInPlainEnglish() throws {
        let folder = meetings.appendingPathComponent("Elm Park")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "my own notes".write(to: folder.appendingPathComponent("Elm Park.md"), atomically: true, encoding: .utf8)
        let outcome = try SeriesActions.move(try note("Workshop 1"), to: "Elm Park", index: index)
        XCTAssertEqual(outcome.note.document.front.series, "Elm Park")
        XCTAssertEqual(outcome.problems, [NoteIndexError.notASeriesPage("Elm Park").localizedDescription])
        XCTAssertEqual(try page("Elm Park"), "my own notes")
    }

    func testRenameSeriesRenamesFolderNotesAndPage() throws {
        _ = try note("Workshop 1", series: "Elm Park")
        try SeriesLibrary.writeSeriesPage(name: "Elm Park", index: index)
        XCTAssertEqual(try SeriesActions.rename("Elm Park", to: "AI Boost", index: index), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetings.appendingPathComponent("Elm Park").path))
        XCTAssertTrue(try page("AI Boost").hasPrefix("---\nlyra_series: true\n---\n# AI Boost"))
        XCTAssertEqual(index.allNotes().first?.document.front.series, "AI Boost")
    }

    func testRetitleRenamesTheFileInItsSeries() throws {
        let loaded = try note("Workshop 1", series: "Elm Park")
        let outcome = try SeriesActions.retitle(loaded, to: "Discovery", index: index)
        XCTAssertEqual(outcome.note.url.lastPathComponent, prefix + "Discovery.md")
        XCTAssertEqual(outcome.note.url.deletingLastPathComponent().lastPathComponent, "Elm Park")
        XCTAssertEqual(outcome.note.document.front.title, "Discovery")
        XCTAssertTrue(try page("Elm Park").contains("|Discovery]]"))
    }

    func testBlankTitleChangesNothing() throws {
        let loaded = try note("Workshop 1")
        XCTAssertEqual(try SeriesActions.retitle(loaded, to: "   ", index: index).note.url, loaded.url)
    }

    func testRejectRemembersNotRelated() throws {
        let folder = vault.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meeting = Meeting(title: "Chat", appName: "Zoom", startedAt: date)
        meeting.seriesSuggestion = "Elm Park"
        try meeting.save(in: folder)
        try SeriesActions.reject(meetingFolder: folder)
        XCTAssertEqual(try Meeting.load(from: folder).seriesRejected, true)
    }
    // MARK: Notes filed in a sidebar folder

    private func filed(_ title: String, series: String? = nil) throws -> LoadedNote {
        _ = try? MeetingFolders(index: index).create("Clients")
        let loaded = try note(title, series: series)
        let url = meetings.appendingPathComponent("Clients/" + loaded.url.lastPathComponent)
        try FileManager.default.moveItem(at: loaded.url, to: url)
        return try index.load(loaded.document.front.lyraID, hint: url)
    }

    func testRetitleKeepsAFiledNoteInItsFolder() throws {
        let outcome = try SeriesActions.retitle(try filed("Workshop 1", series: "Elm Park"), to: "Discovery", index: index)
        XCTAssertEqual(outcome.note.url.lastPathComponent, prefix + "Discovery.md")
        XCTAssertEqual(outcome.note.url.deletingLastPathComponent().lastPathComponent, "Clients")
        XCTAssertTrue(try page("Elm Park").contains("|Discovery]]"))
    }

    func testAddingAFiledNoteToASeriesKeepsItFiled() throws {
        let outcome = try SeriesActions.move(try filed("Workshop 1"), to: "Elm Park", index: index)
        XCTAssertEqual(outcome.note.document.front.series, "Elm Park")
        XCTAssertEqual(outcome.note.url.deletingLastPathComponent().lastPathComponent, "Clients")
        XCTAssertTrue(try page("Elm Park").contains("[[\(prefix)Workshop 1|Workshop 1]]"))
    }

    func testRelocateKeepsAFiledNoteInItsFolder() throws {
        let moved = try index.relocate(try filed("Workshop 1"), title: "Workshop 1", series: "Other")
        XCTAssertEqual(moved.url.deletingLastPathComponent().lastPathComponent, "Clients")
        XCTAssertEqual(moved.document.myNotes, "- mine")
    }
}
