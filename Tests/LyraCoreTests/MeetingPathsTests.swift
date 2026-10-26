import XCTest
@testable import LyraCore

final class MeetingPathsTests: XCTestCase {
    let perth = TimeZone(identifier: "Australia/Perth")!
    var root: URL!
    var notes: URL!
    var paths: MeetingPaths!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("rec")
        notes = base.appendingPathComponent("notes")
        paths = MeetingPaths(recordingsRoot: root, notesDir: notes)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // 2026-11-01 17:00 Perth (UTC+8) = 09:00 UTC
    var date: Date { Date(timeIntervalSince1970: 1_793_523_600) }

    func meeting(_ title: String, app: String = "Zoom") -> Meeting {
        Meeting(id: UUID(), title: title, appName: app, bundleID: nil, startedAt: date, endedAt: nil, warnings: [])
    }

    func testFolderName() {
        XCTAssertEqual(paths.folderName(title: "Elm Park Workshop 2", startedAt: date, timeZone: perth),
                       "2026-11-01 1700 — Elm Park Workshop 2")
    }

    func testSanitisesTitle() {
        let n = paths.folderName(title: "Q3: plan/review 🚀", startedAt: date, timeZone: perth)
        XCTAssertFalse(n.contains("/")); XCTAssertFalse(n.contains(":"))
        XCTAssertTrue(n.contains("🚀"))
        let long = paths.folderName(title: String(repeating: "a", count: 200), startedAt: date, timeZone: perth)
        XCTAssertLessThanOrEqual(long.count, 120)
        let emoji = paths.folderName(title: String(repeating: "🚀", count: 200), startedAt: date, timeZone: perth)
        XCTAssertTrue(emoji.hasSuffix("🚀"))
    }

    func testEmptyTitleFallsBackToAppName() throws {
        let n = try paths.reserve(for: meeting("  "), timeZone: perth).folder.lastPathComponent
        XCTAssertTrue(n.hasSuffix("— Zoom"))
    }

    func testReserveNeverOverwrites() throws {
        let m = meeting("Sync")
        let a = try paths.reserve(for: m, timeZone: perth)
        let b = try paths.reserve(for: m, timeZone: perth)
        XCTAssertEqual(a.folder.lastPathComponent, "2026-11-01 1700 — Sync")
        XCTAssertTrue(b.folder.lastPathComponent.hasSuffix(" (2)"))
        XCTAssertEqual(b.note.lastPathComponent, b.folder.lastPathComponent + ".md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.note.path))
    }
}
