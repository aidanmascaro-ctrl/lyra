import XCTest
@testable import LyraCore

final class NoteBlocksTests: XCTestCase {
    func testRoundTripsAllAllowedFormatting() {
        let md = """
        # Big
        ## Small
        Plain **bold** and <u>under</u> text
        - point
          - child
        1. first
        2. second
        - <span class="lyra">Claude's detail</span>
        """
        let blocks = NoteMarkdown.parse(md)
        XCTAssertEqual(blocks.map(\.kind), [.heading1, .heading2, .paragraph, .bullet, .bullet, .numbered, .numbered, .bullet])
        XCTAssertEqual(blocks[4].indent, 1)
        XCTAssertEqual(blocks[2].runs, [InlineRun(text: "Plain ", bold: false, underline: false),
                                        InlineRun(text: "bold", bold: true, underline: false),
                                        InlineRun(text: " and ", bold: false, underline: false),
                                        InlineRun(text: "under", bold: false, underline: true),
                                        InlineRun(text: " text", bold: false, underline: false)])
        XCTAssertTrue(blocks[7].byClaude)
        XCTAssertEqual(blocks[7].plainText, "Claude's detail")
        XCTAssertEqual(NoteMarkdown.render(blocks), md)
    }

    func testUnknownMarkdownSurvivesAsPlainParagraph() {
        let md = "> a quote with [[Link]] and `code`"
        XCTAssertEqual(NoteMarkdown.render(NoteMarkdown.parse(md)), md)
    }

    func testIndentIsCappedAtThreeLevels() {
        let blocks = NoteMarkdown.parse("- a\n          - deep")
        XCTAssertEqual(blocks[1].indent, 3)
        XCTAssertEqual(NoteMarkdown.render(blocks), "- a\n      - deep")
    }

    func testNumberedItemsRestartAfterAnInterruption() {
        let blocks = NoteMarkdown.parse("1. a\n1. b\ntext\n1. c")
        XCTAssertEqual(NoteMarkdown.render(blocks), "1. a\n2. b\ntext\n1. c")
    }

    func testNestedNumberingSurvivesChildBullets() {
        let md = "1. a\n  - child\n2. b"
        XCTAssertEqual(NoteMarkdown.render(NoteMarkdown.parse(md)), md)
    }

    func testUnmatchedMarkersStayLiteral() {
        let md = "price is 2 ** 3 and a <u> tag"
        let blocks = NoteMarkdown.parse(md)
        XCTAssertEqual(blocks[0].runs, [InlineRun(text: md, bold: false, underline: false)])
        XCTAssertEqual(NoteMarkdown.render(blocks), md)
    }

    func testBoldAndUnderlineTogether() {
        let md = "**<u>both</u>** done"
        let blocks = NoteMarkdown.parse(md)
        XCTAssertEqual(blocks[0].runs.first, InlineRun(text: "both", bold: true, underline: true))
        XCTAssertEqual(NoteMarkdown.render(blocks), md)
    }

    func testBlankLinesAndClaudeParagraphsRoundTrip() {
        let md = "one\n\n<span class=\"lyra\">two</span>\n## <span class=\"lyra\">Head</span>"
        let blocks = NoteMarkdown.parse(md)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertTrue(blocks[2].byClaude)
        XCTAssertTrue(blocks[3].byClaude)
        XCTAssertEqual(NoteMarkdown.render(blocks), md)
    }

    func testEmptyInputHasNoBlocks() {
        XCTAssertEqual(NoteMarkdown.parse(""), [])
        XCTAssertEqual(NoteMarkdown.render([]), "")
    }

    func testNumberedBlockAtDeepestIndentRoundTrips() {
        let md = "      1. x\n      2. y"
        XCTAssertEqual(NoteMarkdown.render(NoteMarkdown.parse(md)), md)
    }
}
