import XCTest
@testable import LyraCore

/// Dividers and pictures: lines Lyra keeps exactly as written.
final class NoteMediaBlocksTests: XCTestCase {
    func testDividersReadAndWriteBackAsTyped() {
        let md = "a\n\n***\n- b\n\n---\n___  \nc"
        let blocks = NoteMarkdown.parse(md)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph, .divider, .bullet, .paragraph, .divider, .divider, .paragraph])
        XCTAssertEqual(blocks[2].plainText, "")
        XCTAssertEqual(NoteMarkdown.render(blocks), md)
    }

    func testDashesUnderTextStayText() {
        // Obsidian reads "text\n---" as a heading underline, so Lyra leaves it alone.
        let blocks = NoteMarkdown.parse("Title\n---")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(NoteMarkdown.render(blocks), "Title\n---")
        XCTAssertEqual(NoteMarkdown.parse("Title\n***").map(\.kind), [.paragraph, .divider])
        XCTAssertEqual(NoteMarkdown.parse("---").map(\.kind), [.divider])
        XCTAssertEqual(NoteMarkdown.parse("- a\n---").map(\.kind), [.bullet, .divider])
    }

    func testADashDividerThatEndsUpUnderTextIsWrittenAsStars() {
        var blocks = NoteMarkdown.parse("a\n\n---")
        blocks.remove(at: 1)  // the blank line between them deleted
        XCTAssertEqual(NoteMarkdown.render(blocks), "a\n***")
        XCTAssertEqual(NoteMarkdown.parse(NoteMarkdown.render(blocks)).map(\.kind), [.paragraph, .divider])
    }

    func testANewDividerIsWrittenAsStars() {
        XCTAssertEqual(NoteMarkdown.render([NoteBlock(kind: .paragraph, runs: [.init(text: "x")]), NoteBlock(kind: .divider, runs: [])]),
                       "x\n***")
    }

    func testPictureLinesRoundTrip() {
        let md = "![[Pasted image 20261110143012.png]]\n![[photo.JPG|300]]\n![a cat](pics/My%20cat.webp)\nsee ![[x.png]] here\n![[Note]]"
        let blocks = NoteMarkdown.parse(md)
        XCTAssertEqual(blocks.map(\.kind), [.image, .image, .image, .paragraph, .paragraph])
        XCTAssertEqual(blocks[0].media, "![[Pasted image 20261110143012.png]]")
        XCTAssertEqual(NoteMarkdown.render(blocks), md)
    }

    func testImageTargets() {
        XCTAssertEqual(NoteMarkdown.imageTarget(of: "![[Pasted image 1.png]]"), "Pasted image 1.png")
        XCTAssertEqual(NoteMarkdown.imageTarget(of: "![[photo.jpg|300]]"), "photo.jpg")
        XCTAssertEqual(NoteMarkdown.imageTarget(of: "![a cat](pics/My%20cat.webp)"), "pics/My cat.webp")
        XCTAssertEqual(NoteMarkdown.imageTarget(of: "![](<pics/a b.png>)"), "pics/a b.png")
        XCTAssertNil(NoteMarkdown.imageTarget(of: "![[Some note]]"))
        XCTAssertNil(NoteMarkdown.imageTarget(of: "![[a.png]] trailing"))
        XCTAssertEqual(NoteMarkdown.imageLine(fileName: "Pasted image 1.png"), "![[Pasted image 1.png]]")
    }

    func testPictureAndDividerSurviveTheEditorText() {
        let blocks = [NoteBlock(kind: .paragraph, runs: [.init(text: "before")]),
                      NoteBlock(kind: .image, runs: [], media: "![[a.png]]"),
                      NoteBlock(kind: .divider, runs: [], media: "***"),
                      NoteBlock(kind: .bullet, runs: [.init(text: "after")])]
        let text = NoteText.attributed(blocks)
        XCTAssertEqual(text.string, "before\n\u{FFFC}\n\u{FFFC}\nafter")
        XCTAssertEqual(NoteText.blocks(text), blocks)
        XCTAssertEqual(blocks.map(NoteText.length(of:)), [6, 1, 1, 5])
    }

    func testAPictureAtTheEndSurvivesTheEditorText() {
        let blocks = [NoteBlock(kind: .paragraph, runs: [.init(text: "x")]), NoteBlock(kind: .image, runs: [], media: "![[a.png]]")]
        XCTAssertEqual(NoteText.blocks(NoteText.attributed(blocks)), blocks)
    }

    func testPicturesAreNeverNewNotes() {
        let mine = [NoteBlock(kind: .image, runs: [], media: "![[a.png]]"), NoteBlock(kind: .divider, runs: [], media: "***")]
        XCTAssertEqual(ExpandedMerge.newNotes(myNotes: mine, expanded: []), [])
    }
}

final class NoteMediaTextRepairTests: XCTestCase {
    private let image = NoteBlock(kind: .image, runs: [], media: "![[a.png]]")

    func testAPictureJoinedOntoTextIsSplitBackOut() {
        let text = NSMutableAttributedString(attributedString: NoteText.attributed(
            [NoteBlock(kind: .paragraph, runs: [.init(text: "ab")]), image, NoteBlock(kind: .paragraph, runs: [.init(text: "cd")])]))
        // Delete both newlines: "ab\u{FFFC}cd" on one line.
        text.deleteCharacters(in: NSRange(location: 4, length: 1))
        text.deleteCharacters(in: NSRange(location: 2, length: 1))
        XCTAssertEqual(NoteText.blocks(text), [NoteBlock(kind: .paragraph, runs: [.init(text: "ab")]), image,
                                               NoteBlock(kind: .paragraph, runs: [.init(text: "cd")])])
    }

    func testTextTypedWithAPicturesKeysIsText() {
        let text = NSMutableAttributedString(attributedString: NoteText.attributed([image, NoteBlock(kind: .paragraph, runs: [.init(text: "x")])]))
        let keys = text.attributes(at: 0, effectiveRange: nil)
        text.replaceCharacters(in: NSRange(location: 0, length: 1), with: NSAttributedString(string: "hi", attributes: keys))
        XCTAssertEqual(NoteText.blocks(text).map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(NoteText.blocks(text)[0].plainText, "hi")
    }

    func testAPictureWhoseCharacterWasDeletedIsAnEmptyLine() {
        let text = NSMutableAttributedString(attributedString: NoteText.attributed([image, NoteBlock(kind: .paragraph, runs: [.init(text: "x")])]))
        text.deleteCharacters(in: NSRange(location: 0, length: 1))
        XCTAssertEqual(NoteText.blocks(text), [NoteBlock(kind: .paragraph, runs: []), NoteBlock(kind: .paragraph, runs: [.init(text: "x")])])
    }

    func testALonePictureIsNeverHeldAsAnEmptyBlock() {
        XCTAssertNil(NoteText.emptyBlock(of: [image]))
    }
}
