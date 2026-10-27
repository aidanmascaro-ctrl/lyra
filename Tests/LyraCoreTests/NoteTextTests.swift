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

    func testTwoEmptyTrailingBlocksKeepTheirOwnKinds() {
        for blocks in [[b("x", .heading1), b("", .heading1), b("", .paragraph)],
                       [b("", .paragraph), b("", .bullet)],
                       [b("", .numbered, indent: 2, grey: true), b("", .heading2, grey: true)]] {
            XCTAssertEqual(NoteText.blocks(NoteText.attributed(blocks)), blocks)
        }
    }

    func testEmptyTextHasNoBlocks() {
        XCTAssertEqual(NoteText.attributed([]).string, "")
        XCTAssertEqual(NoteText.blocks(NSAttributedString(string: "")), [])
    }

    func testPlainTextWithoutKeysReadsAsParagraphs() {
        XCTAssertEqual(NoteText.blocks(NSAttributedString(string: "a\nb")), [b("a", .paragraph), b("b", .paragraph)])
        let bulletLine = NoteText.attributed([b("a")])
        let typedReturn = NSMutableAttributedString(attributedString: bulletLine)
        typedReturn.append(NSAttributedString(string: "\n", attributes: bulletLine.attributes(at: 0, effectiveRange: nil)))
        XCTAssertEqual(NoteText.blocks(typedReturn), [b("a"), b("", .paragraph)])
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

    /// "- " typed on the empty first line of an empty note: the line becomes an empty bullet with no characters
    /// of its own, so nothing in the text can carry its kind. The editor keeps it as its empty block instead.
    func testShortcutOnTheEmptyFirstLineSurvivesTheRoundTrip() {
        for (typed, kind) in [("-", BlockKind.bullet), ("1.", .numbered), ("#", .heading1), ("##", .heading2)] {
            let shortcut = NoteText.shortcut(forLinePrefix: typed + " ")
            XCTAssertEqual(shortcut?.0, kind, typed)
            let after = [b("", kind)]
            let text = NoteText.attributed(after)
            XCTAssertEqual(text.string, "")
            XCTAssertEqual(NoteText.blocks(text, emptyBlock: NoteText.emptyBlock(of: after)), after, typed)
        }
    }

    func testEmptyBlockIsOnlyKeptForAnEmptyText() {
        XCTAssertNil(NoteText.emptyBlock(of: []))
        XCTAssertNil(NoteText.emptyBlock(of: [b("x")]))
        XCTAssertNil(NoteText.emptyBlock(of: [b("", .paragraph)]), "an empty note reads as no blocks, as before")
        XCTAssertNil(NoteText.emptyBlock(of: [b("", .heading1), b("", .paragraph)]))
        XCTAssertEqual(NoteText.emptyBlock(of: [b("", .bullet, indent: 1)]), b("", .bullet, indent: 1))
        // Once there is text, the text alone says what the blocks are.
        let typed = NoteText.attributed([b("a", .paragraph)])
        XCTAssertEqual(NoteText.blocks(typed, emptyBlock: b("", .heading1)), [b("a", .paragraph)])
        XCTAssertEqual(NoteText.blocks(NSAttributedString(string: ""), emptyBlock: nil), [])
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
