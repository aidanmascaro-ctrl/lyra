import XCTest
@testable import LyraCore

final class CallWatchHealthTests: XCTestCase {
    private func health(_ looks: [CallLook]) -> CallWatchHealth {
        var health = CallWatchHealth()
        for look in looks { health.record(look) }
        return health
    }

    func testNoWarningWhenTheWindowWasSeenEvenOnce() {
        XCTAssertNil(health([.noPermission, .noCallWindow, .seen, .offScreen]).warning)
    }

    func testNoWarningWhenNeverLookedFor() {
        XCTAssertNil(CallWatchHealth().warning)
    }

    func testNoPermissionSaysWhereToTurnItOn() throws {
        let warning = try XCTUnwrap(health([.noPermission, .noPermission]).warning)
        XCTAssertTrue(warning.contains("Screen Recording is off"))
        XCTAssertTrue(warning.contains("System Settings"))
    }

    func testTheCommonestMissGivesTheReason() throws {
        let warning = try XCTUnwrap(health([.noCallWindow, .offScreen, .offScreen, .captureFailed]).warning)
        XCTAssertTrue(warning.contains("another desktop"), warning)
    }

    /// Permission off for a moment, then the call tab hidden for longer: permission is still the reason given.
    func testNoPermissionComesFirst() throws {
        let warning = try XCTUnwrap(health([.noPermission, .noCallWindow, .noCallWindow, .noCallWindow]).warning)
        XCTAssertTrue(warning.contains("Screen Recording is off"), warning)
    }

    func testNothingCountedWritesNoFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try CallWatchHealth().save(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(CallWatchHealth.fileName).path))
    }

    func testEachMissHasItsOwnReason() {
        let reasons = [CallLook.noPermission, .noCallWindow, .offScreen, .captureFailed].compactMap { health([$0]).warning }
        XCTAssertEqual(Set(reasons).count, 4)
    }

    func testSavesAndLoadsCountsOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = health([.seen, .noCallWindow, .noCallWindow])
        try saved.save(in: folder)
        XCTAssertEqual(CallWatchHealth.load(from: folder), saved)
        XCTAssertEqual(CallWatchHealth.load(from: folder).counts[.noCallWindow], 2)
    }

    func testMissingOrBrokenFileCountsNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(CallWatchHealth.load(from: folder), CallWatchHealth())
        try Data("not json".utf8).write(to: folder.appendingPathComponent(CallWatchHealth.fileName))
        XCTAssertEqual(CallWatchHealth.load(from: folder), CallWatchHealth())
    }
}
