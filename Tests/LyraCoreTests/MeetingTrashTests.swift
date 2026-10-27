import XCTest
@testable import LyraCore

final class MeetingTrashTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var recordings: URL!
    private var index: NoteIndex!
    private var trashed: [URL] = []
    private let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 27; c.hour = 4; c.minute = 5
        return Calendar.current.date(from: c)!
    }()

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTrashTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        recordings = vault.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
        trashed = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    /// A stand-in for the Trash: the item is moved into a folder inside the test's own temp dir.
    private lazy var fakeTrash: (URL) throws -> Void = { [self] url in
        let bin = vault.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        trashed.append(url)
    }

    private struct Made { let id: UUID; let note: URL; let folder: URL }

    private func make(_ title: String, series: String? = nil, withFolder: Bool = true) throws -> Made {
        let id = UUID()
        let folder = recordings.appendingPathComponent(title, isDirectory: true)
        if withFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("meeting.json"))
        }
        let front = NoteFrontmatter(lyraID: id, title: title, date: date, app: "Zoom", durationMin: 5,
                                    recordings: folder, series: series, summary: "Talked \(title)")
        let doc = NoteDocument(front: front, warnings: [], myNotes: "- mine", expanded: "", transcript: "")
        let dir = series.map { meetings.appendingPathComponent($0) } ?? meetings!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(title + ".md")
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
        return Made(id: id, note: url, folder: folder)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testTrashesTheNoteAndTheRecordingsFolderNoteFirst() throws {
        let a = try make("Alpha")
        let other = try make("Other")
        let problems = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["Alpha.md", "Alpha"])
        XCTAssertFalse(exists(a.note)); XCTAssertFalse(exists(a.folder))
        XCTAssertTrue(exists(other.note)); XCTAssertTrue(exists(other.folder))
    }

    func testMissingNoteStillTrashesTheFolderAndSaysSo() throws {
        let a = try make("Alpha")
        try FileManager.default.removeItem(at: a.note)
        let problems = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("couldn't find"))
        XCTAssertFalse(exists(a.folder))
    }

    func testMissingFolderStillTrashesTheNoteAndSaysSo() throws {
        let a = try make("Alpha", withFolder: false)
        let problems = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("recordings"))
        XCTAssertFalse(exists(a.note))
    }

    func testNilFolderTrashesOnlyTheNote() throws {
        let a = try make("Alpha")
        let problems = MeetingTrash.trash(id: a.id, folder: nil, index: index, trash: fakeTrash)
        XCTAssertEqual(problems, [])
        XCTAssertFalse(exists(a.note)); XCTAssertTrue(exists(a.folder))
    }

    func testFailedNoteMoveLeavesTheRecordingsAlone() throws {
        let a = try make("Alpha")
        struct Nope: Error {}
        let problems = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: { _ in throw Nope() })
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(exists(a.note)); XCTAssertTrue(exists(a.folder))
    }

    func testFailedFolderMoveIsReportedAfterTheNoteWentToTheTrash() throws {
        let a = try make("Alpha")
        struct Nope: Error {}
        let problems = MeetingTrash.trash(id: a.id, folder: a.folder, index: index) { url in
            if url == a.folder { throw Nope() }
            try self.fakeTrash(url)
        }
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("recordings"))
        XCTAssertFalse(exists(a.note)); XCTAssertTrue(exists(a.folder))
    }

    func testSeriesPageIsRewrittenWithoutTheTrashedMeeting() throws {
        let a = try make("Workshop 1", series: "Elm Park")
        _ = try make("Workshop 2", series: "Elm Park")
        try SeriesLibrary.writeSeriesPage(name: "Elm Park", index: index)
        let problems = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertEqual(problems, [])
        let page = try String(contentsOf: meetings.appendingPathComponent("Elm Park/Elm Park.md"), encoding: .utf8)
        XCTAssertFalse(page.contains("Workshop 1"))
        XCTAssertTrue(page.contains("Workshop 2"))
    }

    func testLastMeetingOfASeriesTrashesThePageAndTheEmptyFolder() throws {
        let a = try make("Workshop 1", series: "Elm Park")
        try SeriesLibrary.writeSeriesPage(name: "Elm Park", index: index)
        let seriesFolder = meetings.appendingPathComponent("Elm Park")
        let problems = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertEqual(problems, [])
        XCTAssertFalse(exists(seriesFolder.appendingPathComponent("Elm Park.md")))
        XCTAssertFalse(exists(seriesFolder))
        XCTAssertTrue(exists(meetings))
    }

    func testSeriesFolderWithOtherFilesIsKept() throws {
        let a = try make("Workshop 1", series: "Elm Park")
        try SeriesLibrary.writeSeriesPage(name: "Elm Park", index: index)
        let mine = meetings.appendingPathComponent("Elm Park/My own note.md")
        try Data("hand written".utf8).write(to: mine)
        _ = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertTrue(exists(mine))
    }

    func testHandWrittenNoteWithTheSeriesNameIsNeverTrashed() throws {
        let a = try make("Workshop 1", series: "Elm Park")
        let handWritten = meetings.appendingPathComponent("Elm Park/Elm Park.md")
        try Data("my own page".utf8).write(to: handWritten)
        _ = MeetingTrash.trash(id: a.id, folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertTrue(exists(handWritten))
    }

    func testUnknownMeetingTrashesNothingButItsFolder() throws {
        let a = try make("Alpha")
        let problems = MeetingTrash.trash(id: UUID(), folder: a.folder, index: index, trash: fakeTrash)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(exists(a.note))
    }
}
