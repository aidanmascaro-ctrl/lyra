import XCTest
@testable import LyraCore

final class NoteTextTests: XCTestCase {
    private func b(_ text: String, _ kind: BlockKind = .bullet, indent: Int = 0, grey: Bool = false) -> NoteBlock {
        NoteBlock(kind: kind, indent: indent, runs: text.isEmpty ? [] : [.init(text: text)], byClaude: grey)
    }

    func testAttributedRoundTrip() {
        let blocks = [
            b("Big", .heading1),
            b("Small", .heading2, grey: true),
            NoteBlock(kind: .paragraph, runs: [.init(text: "Plain "), .init(text: "bold", bold: true),
                                               .init(text: " and "), .init(text: "both", bold: true, underline: true)]),
            b("", .paragraph),
            b("point"),
            b("child", indent: 2, grey: true),
            b("first", .numbered),
            b("", .numbered, indent: 1),
            b("second", .numbered),
            b("", .bullet, indent: 3),
        ]
        let text = NoteText.attributed(blocks)
        XCTAssertEqual(text.string, "Big\nSmall\nPlain bold and both\n\npoint\nchild\nfirst\n\nsecond\n")
        XCTAssertEqual(NoteText.blocks(text), blocks)
    }

    func testEmptyTextHasNoBlocks() {
        XCTAssertEqual(NoteText.attributed([]).string, "")
        XCTAssertEqual(NoteText.blocks(NSAttributedString(string: "")), [])
    }

    func testPlainTextWithoutKeysReadsAsParagraphs() {
        XCTAssertEqual(NoteText.blocks(NSAttributedString(string: "a\nb")), [b("a", .paragraph), b("b", .paragraph)])
    }

    func testShortcutRecognition() {
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "- ")?.0, .bullet)
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "- ")?.consumed, 2)
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "* ")?.0, .bullet)
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "1. ")?.0, .numbered)
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "1. ")?.consumed, 3)
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "# ")?.0, .heading1)
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "## ")?.0, .heading2)
        XCTAssertEqual(NoteText.shortcut(forLinePrefix: "## ")?.consumed, 3)
        for miss in ["-", "#", "-x ", "hello - ", "### ", " - ", ""] {
            XCTAssertNil(NoteText.shortcut(forLinePrefix: miss), miss)
        }
    }

    func testListContinuationNumbersUp() {
        let next = NoteText.continuation(after: b("first", .numbered, indent: 1, grey: true))
        XCTAssertEqual(next, b("", .numbered, indent: 1))
        let rendered = NoteMarkdown.render([b("first", .numbered, indent: 1), next!])
        XCTAssertEqual(rendered, "  1. first\n  2. ")
        XCTAssertEqual(NoteText.continuation(after: b("point", indent: 2)), b("", .bullet, indent: 2))
    }

    func testEmptyListItemEndsList() {
        XCTAssertNil(NoteText.continuation(after: b("", .bullet)))
        XCTAssertNil(NoteText.continuation(after: b("", .numbered, indent: 2)))
    }

    func testNonListBlocksDoNotContinue() {
        XCTAssertNil(NoteText.continuation(after: b("text", .paragraph)))
        XCTAssertNil(NoteText.continuation(after: b("Head", .heading1)))
    }
}
