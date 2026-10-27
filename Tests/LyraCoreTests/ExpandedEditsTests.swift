import XCTest
@testable import LyraCore

final class ExpandedEditsTests: XCTestCase {
    private func block(_ text: String, _ kind: BlockKind = .bullet, indent: Int = 0, grey: Bool = false) -> NoteBlock {
        NoteBlock(kind: kind, indent: indent, runs: [InlineRun(text: text)], byClaude: grey)
    }

    func testAnswerBecomesGreyBlocks() {
        let blocks = ExpandedEdits.greyBlocks(from: "They said **Friday**.\n\n- and the budget")
        XCTAssertEqual(blocks.map(\.plainText), ["They said Friday.", "and the budget"])
        XCTAssertTrue(blocks.allSatisfy(\.byClaude))
    }

    func testInsertUnderListItemGoesAfterItsGreyChildrenAsDeeperBullets() {
        let doc = [block("pricing"), block("detail", indent: 1, grey: true), block("budget")]
        let result = ExpandedEdits.insert(ExpandedEdits.greyBlocks(from: "Friday."), under: 0, in: doc)
        XCTAssertEqual(result.map(\.plainText), ["pricing", "detail", "Friday.", "budget"])
        XCTAssertEqual(result[2], block("Friday.", .bullet, indent: 1, grey: true))
    }

    func testInsertUnderHeadingKeepsParagraphs() {
        let doc = [block("Pricing", .heading2), block("budget")]
        let result = ExpandedEdits.insert(ExpandedEdits.greyBlocks(from: "Friday."), under: 0, in: doc)
        XCTAssertEqual(result[1], block("Friday.", .paragraph, grey: true))
        XCTAssertEqual(result[2].plainText, "budget")
    }

    func testAppendAddsAtTheEnd() {
        let result = ExpandedEdits.append(ExpandedEdits.greyBlocks(from: "Noted."), to: [block("pricing")])
        XCTAssertEqual(result.map(\.plainText), ["pricing", "Noted."])
        XCTAssertEqual(result.last?.byClaude, true)
    }

    func testRebaseKeepsEditsMadeWhileClaudeWorked() {
        let base = [block("pricing"), block("budget")]
        let result = [block("pricing"), block("more", indent: 1, grey: true), block("budget")]
        let current = [block("intro", .paragraph), block("pricing"), block("budget"), block("typed meanwhile")]
        XCTAssertEqual(ExpandedEdits.rebase(result, base: base, onto: current).map(\.plainText),
                       ["intro", "pricing", "more", "budget", "typed meanwhile"])
    }

    func testRebaseWithAnchorGoneAppends() {
        let base = [block("pricing")]
        let result = [block("pricing"), block("more", indent: 1, grey: true), block("New", .heading2, grey: true)]
        let current = [block("renamed")]
        XCTAssertEqual(ExpandedEdits.rebase(result, base: base, onto: current).map(\.plainText), ["renamed", "more", "New"])
    }

    func testRebaseOntoUnchangedIsTheResult() {
        let base = [block("pricing")]
        let result = [block("pricing"), block("more", indent: 1, grey: true)]
        XCTAssertEqual(ExpandedEdits.rebase(result, base: base, onto: base), result)
    }

    func testBarRequestAddIncludeWeaveInject() {
        XCTAssertEqual(BarRequest.parse("Add a section on the Morningside collab"), .inject("Add a section on the Morningside collab"))
        XCTAssertEqual(BarRequest.parse("  include the budget "), .inject("include the budget"))
        XCTAssertEqual(BarRequest.parse("weave in: the timeline"), .inject("weave in: the timeline"))
        XCTAssertEqual(BarRequest.parse("Did they address the budget?"), .ask("Did they address the budget?"))
        XCTAssertEqual(BarRequest.parse("addition costs?"), .ask("addition costs?"))
        XCTAssertNil(BarRequest.parse("   "))
    }
}
