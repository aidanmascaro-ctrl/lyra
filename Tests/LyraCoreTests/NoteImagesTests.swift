import XCTest
@testable import LyraCore

final class NoteImagesTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-10T06:30:12Z")!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("NoteImagesTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    private var note: URL { meetings.appendingPathComponent("A note.md") }

    private func stamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: now)
    }

    func testSavesBesideTheNoteWithObsidiansNaming() throws {
        let name = try NoteImages.save(Data([1, 2, 3]), ext: "PNG", besideNote: note, now: now)
        XCTAssertEqual(name, "Pasted image \(stamp()).png")
        XCTAssertEqual(try Data(contentsOf: meetings.appendingPathComponent(name)), Data([1, 2, 3]))
    }

    func testNeverOverwritesAnExistingFile() throws {
        let first = try NoteImages.save(Data([1]), ext: "png", besideNote: note, now: now)
        let second = try NoteImages.save(Data([2]), ext: "png", besideNote: note, now: now)
        XCTAssertEqual(second, "Pasted image \(stamp()) 1.png")
        XCTAssertEqual(try Data(contentsOf: meetings.appendingPathComponent(first)), Data([1]))
    }

    func testKeepsOnlyTypesObsidianShows() {
        XCTAssertTrue(NoteImages.keepsOwnBytes(ext: "JPG"))
        XCTAssertFalse(NoteImages.keepsOwnBytes(ext: "heic"))
        XCTAssertFalse(NoteImages.keepsOwnBytes(ext: "tiff"))
    }

    func testResolvesBesideThenByPathThenByName() throws {
        let fm = FileManager.default
        let beside = meetings.appendingPathComponent("a.png")
        try Data([1]).write(to: beside)
        XCTAssertEqual(NoteImages.resolve("a.png", note: note, vaultRoot: vault)?.standardizedFileURL, beside.standardizedFileURL)

        let pics = vault.appendingPathComponent("Pics", isDirectory: true)
        try fm.createDirectory(at: pics, withIntermediateDirectories: true)
        let byPath = pics.appendingPathComponent("b c.png")
        try Data([2]).write(to: byPath)
        XCTAssertEqual(NoteImages.resolve("Pics/b c.png", note: note, vaultRoot: vault)?.standardizedFileURL, byPath.standardizedFileURL)
        XCTAssertEqual(NoteImages.resolve("b c.png", note: note, vaultRoot: vault)?.standardizedFileURL, byPath.standardizedFileURL)

        let hidden = vault.appendingPathComponent(".trash", isDirectory: true)
        try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data([3]).write(to: hidden.appendingPathComponent("gone.png"))
        XCTAssertNil(NoteImages.resolve("gone.png", note: note, vaultRoot: vault))
    }

    func testPicturesBesideTheNoteMoveWithIt() throws {
        let id = UUID()
        let front = NoteFrontmatter(lyraID: id, title: "Workshop", date: now, app: "Zoom", durationMin: 10,
                                    recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true), series: nil)
        let doc = NoteDocument(front: front, warnings: [], myNotes: "![[mine.png]]\n![[shared.png|200]]\n![[Elsewhere/far.png]]",
                               expanded: "![[late.jpg]]", transcript: "")
        let url = meetings.appendingPathComponent("Workshop.md")
        try doc.render().write(to: url, atomically: true, encoding: .utf8)
        for name in ["mine.png", "shared.png", "late.jpg", "unrelated.png"] {
            try Data([1]).write(to: meetings.appendingPathComponent(name))
        }
        let series = meetings.appendingPathComponent("Series", isDirectory: true)
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        try Data([9]).write(to: series.appendingPathComponent("shared.png"))  // taken there: stays put

        let index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
        let moved = try index.move(try index.load(id, hint: url), into: series)

        let fm = FileManager.default
        XCTAssertEqual(moved.note.url.deletingLastPathComponent().standardizedFileURL, series.standardizedFileURL)
        XCTAssertTrue(fm.fileExists(atPath: series.appendingPathComponent("mine.png").path))
        XCTAssertTrue(fm.fileExists(atPath: series.appendingPathComponent("late.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: meetings.appendingPathComponent("shared.png").path))
        XCTAssertEqual(try Data(contentsOf: series.appendingPathComponent("shared.png")), Data([9]))
        XCTAssertTrue(fm.fileExists(atPath: meetings.appendingPathComponent("unrelated.png").path))
    }
}
