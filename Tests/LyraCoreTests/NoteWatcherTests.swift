import XCTest
@testable import LyraCore

final class NoteWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("NoteWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var expectations: [XCTestExpectation] = []
        func expect(_ e: XCTestExpectation) { lock.withLock { expectations.append(e) } }
        func fire() { lock.withLock { expectations.popLast() }?.fulfill() }
    }

    func testSeesAtomicReplacesAgainAndAgain() throws {
        let url = dir.appendingPathComponent("note.md")
        try Data("one".utf8).write(to: url)
        let counter = Counter()
        let watcher = NoteWatcher(url: url, queue: DispatchQueue(label: "test")) { counter.fire() }
        defer { watcher.stop() }

        for text in ["two", "three"] {
            let changed = expectation(description: text)
            counter.expect(changed)
            try NoteIndex.writeAtomically(Data(text.utf8), to: url)
            wait(for: [changed], timeout: 3)
        }
    }

    func testSeesInPlaceWrites() throws {
        let url = dir.appendingPathComponent("note.md")
        try Data("one".utf8).write(to: url)
        let counter = Counter()
        let watcher = NoteWatcher(url: url, queue: DispatchQueue(label: "test")) { counter.fire() }
        defer { watcher.stop() }

        let changed = expectation(description: "write")
        counter.expect(changed)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" more".utf8))
        try handle.close()
        wait(for: [changed], timeout: 3)
    }

    func testFollowsANewURL() throws {
        let first = dir.appendingPathComponent("a.md"), second = dir.appendingPathComponent("b.md")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let counter = Counter()
        let watcher = NoteWatcher(url: first, queue: DispatchQueue(label: "test")) { counter.fire() }
        defer { watcher.stop() }
        watcher.watch(second)

        let changed = expectation(description: "second")
        counter.expect(changed)
        try NoteIndex.writeAtomically(Data("b2".utf8), to: second)
        wait(for: [changed], timeout: 3)
    }
}
