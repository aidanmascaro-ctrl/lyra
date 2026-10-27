import XCTest
@testable import LyraCore

final class PeopleStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("sub/people.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-people-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: dir) }

    func testLearnCreatesThenAppends() throws {
        let store = PeopleStore(fileURL: url)
        let a = try store.learn(name: "Sam", sample: [1, 0])
        XCTAssertEqual(a.samples.count, 1)
        let b = try store.learn(name: "Sam", sample: [0, 1], isOwner: true)
        XCTAssertEqual(b.id, a.id)
        XCTAssertEqual(b.samples.count, 2)
        XCTAssertTrue(b.isOwner)
        XCTAssertTrue(try store.learn(name: "Sam", sample: [1, 0]).isOwner, "owner never flips back")
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(PeopleStore(fileURL: url).all().first?.samples.count, 3, "persisted")
        let p = b.prototype
        XCTAssertEqual(Double(p[0]), 0.5.squareRoot(), accuracy: 1e-6)
    }

    func testNameLookupIgnoresCaseAndSpaces() throws {
        let store = PeopleStore(fileURL: url)
        let a = try store.learn(name: "  Ada   Lovelace \n", sample: [1, 0])
        XCTAssertEqual(a.name, "Ada   Lovelace", "stored name is trimmed, otherwise as typed")
        XCTAssertEqual(store.person(named: "ada lovelace")?.id, a.id)
        XCTAssertEqual(store.person(named: "ADA  LOVELACE ")?.id, a.id)
        XCTAssertEqual(try store.learn(name: "aDa lovelace", sample: [0, 1]).id, a.id)
        XCTAssertNil(store.person(named: "Grace"))
    }

    func testSamplesCappedAt20() throws {
        let store = PeopleStore(fileURL: url)
        for i in 0..<25 { try store.learn(name: "Sam", sample: [Float(i), 1]) }
        let p = try XCTUnwrap(store.person(named: "Sam"))
        XCTAssertEqual(p.samples.count, 20)
        XCTAssertEqual(p.samples.first?[0], 5, "oldest dropped")
        XCTAssertEqual(p.samples.last?[0], 24)
    }

    func testRejectsBadSamples() throws {
        let store = PeopleStore(fileURL: url)
        try store.learn(name: "Sam", sample: [1, 0])
        XCTAssertThrowsError(try store.learn(name: "Sam", sample: [1, 0, 0]))
        XCTAssertThrowsError(try store.learn(name: "Sam", sample: []))
        XCTAssertThrowsError(try store.learn(name: "Sam", sample: [.nan, 1]))
        XCTAssertThrowsError(try store.learn(name: "Sam", sample: [.infinity, 1]))
        XCTAssertThrowsError(try store.learn(name: "  ", sample: [1, 0]))
        XCTAssertEqual(store.person(named: "Sam")?.samples.count, 1)
    }

    func testRename() throws {
        let store = PeopleStore(fileURL: url)
        let a = try store.learn(name: "Sam", sample: [1, 0])
        try store.learn(name: "Kim", sample: [0, 1])
        try store.rename(a.id, to: " Samuel ")
        XCTAssertEqual(store.person(named: "samuel")?.name, "Samuel")
        XCTAssertNil(store.person(named: "Sam"))
        XCTAssertThrowsError(try store.rename(a.id, to: "kim"))
        XCTAssertThrowsError(try store.rename(UUID(), to: "X"))
    }

    func testCorruptFileMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data("not json".utf8)
        try junk.write(to: url)
        let store = PeopleStore(fileURL: url)
        XCTAssertTrue(store.all().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let corrupt = try XCTUnwrap(names.first { $0.hasPrefix("people.json.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(corrupt)), junk)
        try store.learn(name: "Sam", sample: [1, 0])
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(corrupt)), junk)
    }

    func testMissingFileIsEmpty() { XCTAssertTrue(PeopleStore(fileURL: url).all().isEmpty) }

    func testFileIsOwnerOnly() throws {
        let store = PeopleStore(fileURL: url)
        try store.learn(name: "Sam", sample: [1, 0])
        func mode(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
    }

    func testSecondWriteStillOwnerOnlyAndLooseDirTightened() throws {
        let sub = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = PeopleStore(fileURL: url)
        try store.learn(name: "Sam", sample: [1, 0])
        try store.learn(name: "Sam", sample: [0, 1])
        func mode(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(sub), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sub.path), ["people.json"], "no temp files left")
    }

    func testSecondCorruptionSameSecondKeepsBothAsides() throws {
        let sub = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        var blobs: [Data] = []
        for i in 0..<3 {  // rapid-fire: stamps will collide
            let junk = Data("junk \(i)".utf8); blobs.append(junk)
            try junk.write(to: url)
            XCTAssertTrue(PeopleStore(fileURL: url).all().isEmpty)
        }
        let asides = try FileManager.default.contentsOfDirectory(atPath: sub.path).filter { $0.hasPrefix("people.json.corrupt-") }
        let found = try asides.map { try Data(contentsOf: sub.appendingPathComponent($0)) }
        XCTAssertEqual(Set(found), Set(blobs))
    }

    func testUnreadableFileIsNotWiped() throws {
        let sub = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let seed = PeopleStore(fileURL: url)
        try seed.learn(name: "Sam", sample: [1, 0])
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let store = PeopleStore(fileURL: url)
        XCTAssertThrowsError(try store.learn(name: "Kim", sample: [0, 1]))
        XCTAssertThrowsError(try store.rename(UUID(), to: "X"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(PeopleStore(fileURL: url).all().count, 1)
    }

    func testCorruptFileThatCannotBeMovedBlocksWrites() throws {
        let sub = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let junk = Data("junk".utf8)
        try junk.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sub.path)  // rename needs dir write
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sub.path) }
        let store = PeopleStore(fileURL: url)
        XCTAssertThrowsError(try store.learn(name: "Sam", sample: [1, 0]))
        XCTAssertEqual(try Data(contentsOf: url), junk)
    }
}

final class PeopleStoreForgetTests: XCTestCase {
    func testForgetTakesOneSampleBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-forget-\(UUID().uuidString)/people.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PeopleStore(fileURL: url)
        _ = try store.learn(name: "Tomas", sample: [1, 0])
        let b = try store.learn(name: "Tomas", sample: [0, 1])
        try store.forget(sample: [0, 1], from: b.id)
        XCTAssertEqual(PeopleStore(fileURL: url).all().first?.samples, [[1, 0]], "persisted")
        try store.forget(sample: [0, 1], from: b.id)  // already gone: nothing happens
        try store.forget(sample: [1, 0], from: b.id)
        XCTAssertEqual(store.all().first?.samples, [], "kept in the list, matching nobody")
        XCTAssertThrowsError(try store.forget(sample: [1, 0], from: UUID()))
    }
}
