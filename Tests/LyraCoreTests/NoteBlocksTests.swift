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
        let md = "one\n\n<span class=\"lyra\">two</span>\n\n## <span class=\"lyra\">Head</span>"
        let blocks = NoteMarkdown.parse(md)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertTrue(blocks[2].byClaude)
        XCTAssertTrue(blocks[4].byClaude)
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

    func testClaudeHeadingAfterTextGetsABlankLineBefore() {
        let blocks = [
            NoteBlock(kind: .bullet, runs: [.init(text: "detail")], byClaude: true),
            NoteBlock(kind: .heading2, runs: [.init(text: "Action items")], byClaude: true),
            NoteBlock(kind: .bullet, runs: [.init(text: "Sam books the shoot")], byClaude: true),
        ]
        let md = NoteMarkdown.render(blocks)
        XCTAssertEqual(md, "- <span class=\"lyra\">detail</span>\n\n## <span class=\"lyra\">Action items</span>\n- <span class=\"lyra\">Sam books the shoot</span>")
        XCTAssertEqual(NoteMarkdown.render(NoteMarkdown.parse(md)), md, "stable once written")
    }

    func testClaudeHeadingAfterBlankLineOrAtStartGetsNoExtraGap() {
        let head = NoteBlock(kind: .heading2, runs: [.init(text: "Decisions")], byClaude: true)
        XCTAssertEqual(NoteMarkdown.render([head]), "## <span class=\"lyra\">Decisions</span>")
        XCTAssertEqual(NoteMarkdown.render([NoteBlock(kind: .paragraph, runs: []), head]),
                       "\n## <span class=\"lyra\">Decisions</span>")
    }

    func testRenderLinesHasOneLinePerBlock() {
        let blocks = NoteMarkdown.parse("- a")
            + [NoteBlock(kind: .heading2, runs: [.init(text: "H")], byClaude: true)]
            + NoteMarkdown.parse("1. x")
        XCTAssertEqual(NoteMarkdown.renderLines(blocks), ["- a", "## <span class=\"lyra\">H</span>", "1. x"])
    }

    /// Aidan's own notes, headings glued to text included, come back byte for byte.
    func testAidansNotesRoundTripExactly() {
        let md = """
        frameworks when approaching clients

        discovery call / meeting

        whats consulting:

        - problem solvers
        - icecube analogy, sometimes slow and empathetic
        identify the bottle neck of the business
        ## my heading
        engagement cycle:
        # Big one
        1. discover: learn about bis and understand, map workflows. think like a gp
        2. decide

        fishbone diagram: root cause analysis
        - <span class="lyra">earlier grey line</span>
        ## <span class="lyra">Glued heading from an old Lyra</span>

        """
        XCTAssertEqual(NoteMarkdown.render(NoteMarkdown.parse(md)).replacingOccurrences(
            of: "\n\n## <span class=\"lyra\">Glued", with: "\n## <span class=\"lyra\">Glued"), md)
        let aidanOnly = md.components(separatedBy: "\n- <span")[0]
        XCTAssertEqual(NoteMarkdown.render(NoteMarkdown.parse(aidanOnly)), aidanOnly)
    }
}
