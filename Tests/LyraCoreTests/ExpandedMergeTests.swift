import XCTest
@testable import LyraCore

final class ExpandedMergeTests: XCTestCase {
    private func b(_ text: String, _ kind: BlockKind = .bullet, indent: Int = 0, grey: Bool = false) -> NoteBlock {
        NoteBlock(kind: kind, indent: indent, runs: [.init(text: text)], byClaude: grey)
    }

    func testEditedGreyBecomesWhite() {
        let grey = NoteBlock(kind: .bullet, indent: 1, runs: [.init(text: "detail", bold: false, underline: false)], byClaude: true)
        var edited = grey; edited.runs[0].text = "detail, edited"
        let settled = ExpandedMerge.settle([grey, edited], lyraWrote: ExpandedMerge.hashes(of: [grey]))
        XCTAssertEqual(settled.map(\.byClaude), [true, false])
    }

    func testHashesCoverOnlyGreyBlocks() {
        XCTAssertEqual(ExpandedMerge.hashes(of: [b("white"), b("grey", grey: true)]).count, 1)
    }

    func testSettleLeavesWhiteBlocksAlone() {
        let white = b("mine")
        XCTAssertEqual(ExpandedMerge.settle([white], lyraWrote: []), [white])
    }

    func testNewNotesSinceExpansionCountsOnlyUncoveredPoints() {
        let myNotes = [b("Pricing"), b("Xmas reels"), b("Gift box")]
        let expanded = [b("pricing"), b("Xmas  reels"), b("Gift box budget", indent: 1, grey: true)]
        XCTAssertEqual(ExpandedMerge.newNotes(myNotes: myNotes, expanded: expanded).map(\.plainText), ["Gift box"])
    }

    func testGreyTextDoesNotCoverAPoint() {
        let result = ExpandedMerge.newNotes(myNotes: [b("Gift box")], expanded: [b("Gift box", grey: true)])
        XCTAssertEqual(result.map(\.plainText), ["Gift box"])
    }

    func testBlankMyNotesLinesAreNotNewPoints() {
        XCTAssertTrue(ExpandedMerge.newNotes(myNotes: [b("  ", .paragraph)], expanded: []).isEmpty)
    }

    func testInsertNewNotesAfterPredecessorAndItsGreyChildren() {
        let myNotes = [b("Pricing", .heading2), b("Xmas reels"), b("Gift box")]
        let expanded = [
            b("Xmas reels"), b("grey child", indent: 1, grey: true),
            b("Pricing", .heading2),
        ]
        let merged = ExpandedMerge.insertNewNotes([b("Gift box")], myNotes: myNotes, into: expanded)
        XCTAssertEqual(merged.map(\.plainText), ["Xmas reels", "grey child", "Gift box", "Pricing"])
    }

    func testInsertNewNotesWithNoMatchingPredecessorGoesToEnd() {
        let merged = ExpandedMerge.insertNewNotes([b("Gift box")], myNotes: [b("Gift box")], into: [b("Other")])
        XCTAssertEqual(merged.map(\.plainText), ["Other", "Gift box"])
    }

    func testConsecutiveNewNotesKeepTheirOrder() {
        let myNotes = [b("A"), b("B"), b("C")]
        let merged = ExpandedMerge.insertNewNotes([b("B"), b("C")], myNotes: myNotes, into: [b("A"), b("Z")])
        XCTAssertEqual(merged.map(\.plainText), ["A", "B", "C", "Z"])
    }

    func testStripGreyDropsOnlyClaudeBlocks() {
        let kept = ExpandedMerge.stripGrey([b("mine"), b("claude", grey: true), b("mine too")])
        XCTAssertEqual(kept.map(\.plainText), ["mine", "mine too"])
    }

    func testMoveBlockCarriesChildren() {
        let blocks = [b("a"), b("a1", indent: 1), b("a2", indent: 1), b("b"), b("c")]
        XCTAssertEqual(ExpandedMerge.moveBlock(blocks, from: 0, to: 5).map(\.plainText), ["b", "c", "a", "a1", "a2"])
    }

    func testMoveBlockEarlierInsertsBeforeTarget() {
        let blocks = [b("a"), b("b"), b("b1", indent: 1), b("c")]
        XCTAssertEqual(ExpandedMerge.moveBlock(blocks, from: 1, to: 0).map(\.plainText), ["b", "b1", "a", "c"])
    }

    func testMoveHeadingCarriesSection() {
        let blocks = [b("A", .heading2), b("a1"), b("B", .heading2), b("b1")]
        XCTAssertEqual(ExpandedMerge.moveBlock(blocks, from: 0, to: 4).map(\.plainText), ["B", "b1", "A", "a1"])
    }

    func testHeading2SectionStopsAtNextHeading1() {
        let blocks = [b("A", .heading2), b("a1"), b("Top", .heading1), b("t1")]
        XCTAssertEqual(ExpandedMerge.moveBlock(blocks, from: 0, to: 4).map(\.plainText), ["Top", "t1", "A", "a1"])
    }

    func testMovingIntoOwnSpanIsNoOp() {
        let blocks = [b("a"), b("a1", indent: 1), b("b")]
        XCTAssertEqual(ExpandedMerge.moveBlock(blocks, from: 0, to: 1), blocks)
        XCTAssertEqual(ExpandedMerge.moveBlock(blocks, from: 0, to: 2), blocks)
        XCTAssertEqual(ExpandedMerge.moveBlock(blocks, from: 9, to: 0), blocks)
    }
}
