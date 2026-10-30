import XCTest
@testable import LyraCore

final class MeetingFoldersTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var index: NoteIndex!
    private var folders: MeetingFolders!
    private let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 27; c.hour = 4; c.minute = 5
        return Calendar.current.date(from: c)!
    }()
    private let prefix = "2026-10-27 0405 — "

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingFoldersTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
        folders = MeetingFolders(index: index)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: meetings.appendingPathComponent(path).path)
    }

    private func marker(_ folder: String) throws -> String {
        try String(contentsOf: meetings.appendingPathComponent("\(folder)/\(MeetingFolders.markerName)"), encoding: .utf8)
    }

    private func note(_ title: String, in folder: String? = nil, series: String? = nil) throws -> LoadedNote {
        let front = NoteFrontmatter(lyraID: UUID(), title: title, date: date, app: "Zoom", durationMin: 5,
                                    recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true), series: series)
        let doc = NoteDocument(front: front, warnings: [], myNotes: "- mine", expanded: "", transcript: "")
        let dir = folder.map { meetings.appendingPathComponent($0) } ?? meetings!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(prefix + title + ".md")
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
        return try index.load(front.lyraID, hint: url)
    }

    // MARK: Create and list

    func testCreateMakesTheFolderAndItsMarker() throws {
        let made = try folders.create("  Clients ")
        XCTAssertEqual(made, SidebarFolder(name: "Clients", colour: .grey))
        XCTAssertTrue(exists("Clients/\(MeetingFolders.markerName)"))
        XCTAssertTrue(try marker("Clients").contains("\"colour\""))
        XCTAssertTrue(folders.isFolder(meetings.appendingPathComponent("Clients")))
    }

    func testNewFoldersTakeThePaletteInTurn() throws {
        let colours = try ["A", "B", "C"].map { try folders.create($0).colour }
        XCTAssertEqual(colours, Array(FolderColour.allCases.prefix(3)))
    }

    func testAllListsOnlyMarkedFoldersByName() throws {
        _ = try folders.create("content")
        _ = try folders.create("Clients")
        _ = try folders.create("Personal")
        _ = try note("Workshop", in: "Elm Park")   // a series folder, made by hand
        XCTAssertEqual(folders.all().map(\.name), ["Clients", "content", "Personal"])
    }

    func testUnreadableMarkerReadsAsGrey() throws {
        _ = try folders.create("A")
        _ = try folders.create("Clients")
        try "not json".write(to: meetings.appendingPathComponent("Clients/\(MeetingFolders.markerName)"),
                             atomically: true, encoding: .utf8)
        XCTAssertEqual(folders.all().first { $0.name == "Clients" }?.colour, .grey)
    }

    // MARK: Name rules

    func testBlankAndInvalidNamesAreRefusedInPlainEnglish() {
        XCTAssertThrowsError(try folders.create("   ")) { XCTAssertEqual($0 as? MeetingFoldersError, .emptyName) }
        for bad in ["a/b", "What?", "#tag", "[x]", ".hidden"] {
            XCTAssertThrowsError(try folders.create(bad)) { error in
                XCTAssertEqual(error as? MeetingFoldersError, .invalidName(bad))
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        XCTAssertTrue(folders.all().isEmpty)
    }

    func testNamesOfExistingFoldersOfEitherKindAreTaken() throws {
        _ = try folders.create("Clients")
        _ = try note("Workshop", in: "Elm Park")
        XCTAssertThrowsError(try folders.create("clients")) { XCTAssertEqual($0 as? MeetingFoldersError, .nameTaken("clients")) }
        XCTAssertThrowsError(try folders.create("ELM PARK")) { error in
            XCTAssertEqual(error as? MeetingFoldersError, .nameTaken("ELM PARK"))
            XCTAssertTrue(error.localizedDescription.contains("ELM PARK"))
        }
        XCTAssertFalse(folders.isFolder(meetings.appendingPathComponent("Elm Park")))
    }

    // MARK: Rename and colour

    func testRenameMovesTheFolderWithItsMarkerAndNotes() throws {
        _ = try folders.create("Clients")
        try folders.setColour(.teal, of: "Clients")
        let filed = try note("Workshop", in: "Clients")
        try folders.rename("Clients", to: "Customers")
        XCTAssertFalse(exists("Clients"))
        XCTAssertEqual(folders.all(), [SidebarFolder(name: "Customers", colour: .teal)])
        XCTAssertTrue(exists("Customers/" + filed.url.lastPathComponent))
    }

    func testCaseOnlyRenameWorks() throws {
        _ = try folders.create("clients")
        try folders.rename("clients", to: "Clients")
        XCTAssertEqual(folders.all().map(\.name), ["Clients"])
    }

    func testRenameIntoATakenNameIsRefused() throws {
        _ = try folders.create("Clients")
        _ = try note("Workshop", in: "Elm Park")
        XCTAssertThrowsError(try folders.rename("Clients", to: "elm park")) {
            XCTAssertEqual($0 as? MeetingFoldersError, .nameTaken("elm park"))
        }
        XCTAssertThrowsError(try folders.rename("Nope", to: "Other")) {
            XCTAssertEqual($0 as? MeetingFoldersError, .missingFolder("Nope"))
        }
        XCTAssertThrowsError(try folders.rename("Elm Park", to: "Other")) {   // a series folder isn't a sidebar folder
            XCTAssertEqual($0 as? MeetingFoldersError, .missingFolder("Elm Park"))
        }
        XCTAssertTrue(exists("Clients"))
    }

    func testSetColourRewritesTheMarker() throws {
        _ = try folders.create("Clients")
        try folders.setColour(.purple, of: "Clients")
        XCTAssertEqual(folders.all().first?.colour, .purple)
        XCTAssertThrowsError(try folders.setColour(.red, of: "Nope")) {
            XCTAssertEqual($0 as? MeetingFoldersError, .missingFolder("Nope"))
        }
    }

    // MARK: Which folder a note is in

    func testFolderOfANote() throws {
        _ = try folders.create("Clients")
        XCTAssertEqual(folders.folder(of: try note("A", in: "Clients").url), "Clients")
        XCTAssertNil(folders.folder(of: try note("B", in: "Elm Park").url))
        XCTAssertNil(folders.folder(of: try note("C").url))
    }
}
