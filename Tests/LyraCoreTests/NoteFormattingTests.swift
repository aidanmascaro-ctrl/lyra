import XCTest
@testable import LyraCore

/// Aidan's own Markdown style (list numbers, indents) survives a save; only lines he changed are written fresh.
final class NoteFormattingTests: XCTestCase {
    private func text(_ original: String, edit: ([NoteBlock]) -> [NoteBlock] = { $0 }) -> String {
        NoteFormatting.text(for: edit(NoteMarkdown.parse(original)), keepingStyleOf: original)
    }

    func testUnchangedTextIsWrittenBackExactly() {
        let original = "1. one\n1. two\n1. three\n   - three spaces\n5. five\n\n- tail"
        XCTAssertEqual(text(original), original)
    }

    func testAnEditedLineIsWrittenFreshAndTheRestKeepTheirStyle() {
        let original = "1. one\n1. two\n   - deep"
        let result = text(original) { blocks in
            var blocks = blocks
            blocks[1].runs = [InlineRun(text: "two!")]
            return blocks
        }
        XCTAssertEqual(result, "1. one\n2. two!\n   - deep")
    }

    func testAnAddedLineKeepsItsNeighboursStyle() {
        let original = "3. three\n3. again"
        let result = text(original) { $0 + [NoteBlock(kind: .paragraph, runs: [InlineRun(text: "new")])] }
        XCTAssertEqual(result, "3. three\n3. again\nnew")
    }

    func testOldHeadingMarkersStillMoveToTheCurrentOnes() {
        XCTAssertEqual(text("# Big\n## Small\n1. kept"), "### Big\n#### Small\n1. kept")
    }

    func testNoOriginalGivesTheCanonicalText() {
        let blocks = [NoteBlock(kind: .numbered, runs: [InlineRun(text: "a")]), NoteBlock(kind: .numbered, runs: [InlineRun(text: "b")])]
        XCTAssertEqual(NoteFormatting.text(for: blocks, keepingStyleOf: ""), "1. a\n2. b")
    }

    func testClaudeHeadingStillGetsItsGap() {
        let heading = NoteBlock(kind: .heading1, runs: [InlineRun(text: "Topic")], byClaude: true)
        let original = "1. mine"
        let result = text(original) { $0 + [heading] }
        XCTAssertEqual(result, NoteMarkdown.render(NoteMarkdown.parse(original) + [heading]))
    }
}
