import XCTest
@testable import LyraCore

final class LiveLinesTests: XCTestCase {
    func testVolatileTextReplacesTheOpenLine() {
        var live = LiveLines()
        live.apply(track: .mic, text: "hello", isFinal: false)
        live.apply(track: .mic, text: "hello there", isFinal: false)
        XCTAssertEqual(live.lines.map(\.text), ["hello there"])
        XCTAssertEqual(live.lines.map(\.isFinal), [false])
    }

    func testFinalTextClosesTheLineAndTheNextOneStartsFresh() {
        var live = LiveLines()
        live.apply(track: .mic, text: "hello", isFinal: false)
        live.apply(track: .mic, text: "hello there", isFinal: true)
        live.apply(track: .mic, text: "how are", isFinal: false)
        XCTAssertEqual(live.lines.map(\.text), ["hello there", "how are"])
        XCTAssertEqual(live.lines.map(\.isFinal), [true, false])
    }

    func testFinalWithNoOpenLineAddsAClosedLine() {
        var live = LiveLines()
        live.apply(track: .meeting, text: "morning all", isFinal: true)
        XCTAssertEqual(live.lines.map(\.text), ["morning all"])
        XCTAssertEqual(live.lines.map(\.isFinal), [true])
    }

    /// Each track keeps its own open line, even when the other track has spoken since.
    func testTracksKeepSeparateOpenLines() {
        var live = LiveLines()
        live.apply(track: .meeting, text: "so the", isFinal: false)
        live.apply(track: .mic, text: "yep", isFinal: false)
        live.apply(track: .meeting, text: "so the shoot is friday", isFinal: false)
        XCTAssertEqual(live.lines.map(\.text), ["so the shoot is friday", "yep"])
        XCTAssertEqual(live.lines.map(\.track), [.meeting, .mic])
    }

    func testReplacingKeepsTheLineIdentity() {
        var live = LiveLines()
        live.apply(track: .mic, text: "a", isFinal: false)
        let id = live.lines[0].id
        live.apply(track: .mic, text: "a b", isFinal: true)
        XCTAssertEqual(live.lines[0].id, id)
    }

    func testLabels() {
        var live = LiveLines()
        live.apply(track: .mic, text: "a", isFinal: true)
        live.apply(track: .meeting, text: "b", isFinal: true)
        XCTAssertEqual(live.lines.map(\.label), ["Me", "Them"])
    }
}
