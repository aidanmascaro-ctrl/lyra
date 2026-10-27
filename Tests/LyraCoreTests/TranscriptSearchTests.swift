import XCTest
@testable import LyraCore

final class TranscriptSearchTests: XCTestCase {
    private func line(_ text: String, at start: Double) -> TranscriptLine {
        TranscriptLine(speakerLabel: "Speaker 1", track: .mic, start: start, end: start + 2, text: text)
    }

    func testTranscriptSearchRanksSharedWords() {
        let lines = [
            line("we talked about the weather", at: 0),
            line("the gift box budget is about six hundred", at: 10),
            line("the budget for reels", at: 20),
        ]
        XCTAssertEqual(TranscriptSearch.lines(matching: "gift box budget", in: lines), [1, 2])
    }

    func testTiesBreakByTime() {
        let lines = [line("later budget", at: 30), line("earlier budget", at: 5)]
        XCTAssertEqual(TranscriptSearch.lines(matching: "budget", in: lines), [1, 0])
    }

    func testStopwordsAloneDoNotMatch() {
        XCTAssertTrue(TranscriptSearch.lines(matching: "the and of", in: [line("the cat and the dog of mine", at: 0)]).isEmpty)
    }

    func testRespectsLimit() {
        let lines = (0..<5).map { line("budget \($0)", at: Double($0)) }
        XCTAssertEqual(TranscriptSearch.lines(matching: "budget", in: lines, limit: 2).count, 2)
    }

    func testPunctuationAndCaseAreIgnored() {
        XCTAssertEqual(TranscriptSearch.lines(matching: "Budget!", in: [line("The budget, again.", at: 0)]), [0])
    }
}
