import AppKit
import LyraCore
import XCTest
@testable import Lyra

/// Dividers and pictures in the editor, without a window: each keystroke its own undo group, as the event loop makes them.
@MainActor
final class NoteMediaEditingTests: XCTestCase {
    @MainActor private final class Undo: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        override init() { super.init(); manager.groupsByEvent = false }
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private var view: NoteTextView!
    private var undo: Undo!
    private var folder: URL!

    override func setUp() async throws {
        undo = Undo()
        view = NoteTextView()
        view.delegate = undo
        view.load([])
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteMediaEditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func key(_ action: (NoteTextView) -> Void) {
        undo.manager.beginUndoGrouping()
        action(view)
        undo.manager.endUndoGrouping()
    }

    private func type(_ text: String) {
        for c in text { key { $0.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
    }

    private func text(_ s: String) -> NoteBlock { NoteBlock(kind: .paragraph, runs: s.isEmpty ? [] : [.init(text: s)]) }
    private let picture = NoteBlock(kind: .image, runs: [], media: "![[a.png]]")
    private let divider = NoteBlock(kind: .divider, runs: [])

    func testDashesAndReturnMakeADivider() {
        type("---")
        key { $0.insertNewline(nil) }
        XCTAssertEqual(view.blocks, [divider, text("")])
        type("x")
        XCTAssertEqual(view.blocks, [divider, text("x")])
        XCTAssertEqual(NoteMarkdown.render(view.blocks), "***\nx")
    }

    func testDashesInsideTextStayText() {
        type("a---")
        key { $0.insertNewline(nil) }
        XCTAssertEqual(view.blocks, [text("a---"), text("")])
    }

    func testReturnOnAPictureStartsALineUnderIt() {
        view.load([picture])
        view.setSelectedRange(NSRange(location: 1, length: 0))
        key { $0.insertNewline(nil) }
        XCTAssertEqual(view.blocks, [picture, text("")])
        XCTAssertEqual(view.selectedRange().location, 2)
    }

    func testTypingOnAPictureGoesOnANewLine() {
        view.load([text("a"), picture])
        view.setSelectedRange(NSRange(location: 3, length: 0))  // just after the picture
        type("hi")
        XCTAssertEqual(view.blocks, [text("a"), picture, text("hi")])
        view.setSelectedRange(NSRange(location: 2, length: 0))  // just before it
        type("b")
        XCTAssertEqual(view.blocks, [text("a"), text("b"), picture, text("hi")])
    }

    func testBackspaceAfterAPictureRemovesItAndUndoBringsItBack() {
        view.load([text("a"), picture, text("b")])
        view.setSelectedRange(NSRange(location: 3, length: 0))
        key { $0.deleteBackward(nil) }
        XCTAssertEqual(view.blocks, [text("a"), text("b")])
        undo.manager.undo()
        XCTAssertEqual(view.blocks, [text("a"), picture, text("b")])
    }

    func testBackspaceAtTheStartOfTheLineUnderAPictureRemovesThePicture() {
        view.load([text("a"), picture, text("b")])
        view.setSelectedRange(NSRange(location: 4, length: 0))
        key { $0.deleteBackward(nil) }
        XCTAssertEqual(view.blocks, [text("a"), text("b")])
        XCTAssertEqual(view.selectedRange().location, 2)
    }

    func testBackspaceJustBeforeAPictureNeverJoinsItToText() {
        view.load([text("a"), divider])
        view.setSelectedRange(NSRange(location: 2, length: 0))
        key { $0.deleteBackward(nil) }
        XCTAssertEqual(view.blocks, [text("a"), divider])
    }

    func testDeleteAtTheEndOfTheLineAboveRemovesIt() {
        view.load([text("a"), divider, text("b")])
        view.setSelectedRange(NSRange(location: 1, length: 0))
        key { $0.deleteForward(nil) }
        XCTAssertEqual(view.blocks, [text("a"), text("b")])
    }

    func testASelectedPictureIsRemovedByBackspace() {
        view.load([picture, text("b")])
        view.setSelectedRange(NSRange(location: 0, length: 1))
        key { $0.deleteBackward(nil) }
        XCTAssertEqual(view.blocks, [text("b")])
    }

    func testDeletingAcrossTextNeverPutsAPictureInsideALine() {
        view.load([text("ab"), picture, text("cd")])
        view.setSelectedRange(NSRange(location: 1, length: 2))  // "b" and the newline before the picture
        key { $0.deleteBackward(nil) }
        XCTAssertEqual(view.blocks, [text("a"), picture, text("cd")])
    }

    func testPastedPictureIsSavedBesideTheNoteAndGoesOnItsOwnLine() async throws {
        let note = folder.appendingPathComponent("Note.md")
        view.imageLoader = NoteImageLoader(note: note, vaultRoot: folder)
        view.load([text("a"), text("")])
        view.setSelectedRange(NSRange(location: 2, length: 0))  // the empty line: replaced by the picture
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try XCTUnwrap(NoteTextView.pngData(image)), forType: .png)
        var pasted = false
        key { pasted = $0.pasteImages(from: pasteboard, at: nil) }
        XCTAssertTrue(pasted)
        let blocks = view.blocks
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .image])
        let name = try XCTUnwrap(blocks[1].media.flatMap(NoteMarkdown.imageTarget(of:)))
        XCTAssertTrue(name.hasPrefix("Pasted image "))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        _ = view.image(for: blocks[1].media)  // starts the lookup, off the main thread
        for _ in 0..<100 where view.image(for: blocks[1].media) == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(view.image(for: blocks[1].media))
        pasteboard.releaseGlobally()
    }

    func testTextOnThePasteboardIsNotAPicture() {
        view.imageLoader = NoteImageLoader(note: folder.appendingPathComponent("Note.md"), vaultRoot: folder)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertFalse(view.pasteImages(from: pasteboard, at: nil))
        pasteboard.releaseGlobally()
    }

    func testAPictureIsShownAtItsOwnSizeShrunkToTheColumn() {
        let small = NSImage(size: NSSize(width: 200, height: 100))
        XCTAssertEqual(NoteMediaCell.size(kind: .image, image: small, column: 680), NSSize(width: 200, height: 100))
        let big = NSImage(size: NSSize(width: 1360, height: 400))
        XCTAssertEqual(NoteMediaCell.size(kind: .image, image: big, column: 680), NSSize(width: 680, height: 200))
        XCTAssertEqual(NoteMediaCell.size(kind: .divider, image: nil, column: 680).width, 680)
    }

    func testOnlyAPicturesOwnCharacterIsDrawnAsOne() {
        let styled = NoteStyle.styled(NoteText.attributed([picture, divider, text("x")]))
        XCTAssertTrue(styled.attribute(.attachment, at: 0, effectiveRange: nil) is NoteMediaAttachment)
        XCTAssertNil(styled.attribute(.attachment, at: 1, effectiveRange: nil))  // its "\n"
        XCTAssertTrue(styled.attribute(.attachment, at: 2, effectiveRange: nil) is NoteMediaAttachment)
        XCTAssertNil(styled.attribute(.attachment, at: 4, effectiveRange: nil))
    }

    func testTypingOnASelectedPictureStartsALineUnderIt() {
        view.load([picture, text("b")])
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("x")
        XCTAssertEqual(view.blocks, [picture, text("x"), text("b")])
        view.setSelectedRange(NSRange(location: 0, length: 1))
        key { $0.insertNewline(nil) }
        XCTAssertEqual(view.blocks, [picture, text(""), text("x"), text("b")])
    }

    func testCopyingAPictureCopiesItsLineAndPastingThatLineBringsItBack() {
        view.load([text("a"), picture])
        view.setSelectedRange(NSRange(location: 0, length: 3))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-test-\(UUID().uuidString)"))
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "a\n![[a.png]]")
        pasteboard.releaseGlobally()
        view.load([text("")])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        key { $0.insertText("a\n![[a.png]]", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(view.blocks, [text("a"), picture])
        XCTAssertFalse(view.string.contains("\u{FFFC}\u{FFFC}"))
    }

    func testAStrayPlaceholderCharacterIsNeverPasted() {
        XCTAssertEqual(NoteTextView.plainLines("a\u{FFFC}b"), "ab")
    }

    func testAPastedPictureGoesAfterABulletsChildren() throws {
        let note = folder.appendingPathComponent("Note.md")
        view.imageLoader = NoteImageLoader(note: note, vaultRoot: folder)
        let parent = NoteBlock(kind: .bullet, runs: [.init(text: "p")])
        let child = NoteBlock(kind: .bullet, indent: 1, runs: [.init(text: "c")])
        view.load([parent, child, text("z")])
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)
        key { _ = $0.pasteImages(from: pasteboard, at: nil) }
        XCTAssertEqual(view.blocks.map(\.kind), [.bullet, .bullet, .image, .paragraph])
        pasteboard.releaseGlobally()
    }

    func testAWebAddressDoesNotBeatAPicture() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/cat.png", forType: .string)
        XCTAssertTrue(NoteTextView.pictureWinsOverText(on: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("some words", forType: .string)
        XCTAssertFalse(NoteTextView.pictureWinsOverText(on: pasteboard))
        pasteboard.releaseGlobally()
    }
}
