import AppKit
import LyraCore
import XCTest
@testable import Lyra

/// The editor without a window: typing goes through the same `insertText` / `deleteBackward` AppKit calls, one undo
/// group per keystroke as the event loop would make them.
@MainActor
final class NoteTextViewTests: XCTestCase {
    @MainActor private final class Undo: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        override init() {
            super.init()
            manager.groupsByEvent = false
        }
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private var view: NoteTextView!
    private var undo: Undo!

    override func setUp() async throws {
        undo = Undo()
        view = NoteTextView()
        view.delegate = undo
        view.load([])
    }

    private func key(_ action: (NoteTextView) -> Void) {
        undo.manager.beginUndoGrouping()
        action(view)
        undo.manager.endUndoGrouping()
    }

    private func type(_ text: String) {
        for c in text { key { $0.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
    }

    private func bullet(_ text: String = "") -> NoteBlock {
        NoteBlock(kind: .bullet, runs: text.isEmpty ? [] : [.init(text: text)])
    }

    func testShortcutsOnTheEmptyFirstLine() {
        for (typed, kind) in [("- ", BlockKind.bullet), ("1. ", .numbered), ("# ", .heading1), ("## ", .heading2)] {
            view.load([])
            type(typed)
            XCTAssertEqual(view.blocks, [NoteBlock(kind: kind, runs: [])], typed)
            type("a")
            XCTAssertEqual(view.blocks, [NoteBlock(kind: kind, runs: [.init(text: "a")])], typed)
        }
    }

    func testDeletingTheTextOfALoneBulletLeavesAnEmptyBullet() {
        type("- ab")
        key { $0.deleteBackward(nil) }
        key { $0.deleteBackward(nil) }
        XCTAssertEqual(view.blocks, [bullet()])
        key { $0.deleteBackward(nil) }  // at the start of an empty bullet: back to plain
        XCTAssertEqual(view.blocks, [])
    }

    func testUndoBackToTheEmptyNoteLeavesItPlainAndRedoBringsTheBulletBack() {
        type("- x")
        XCTAssertEqual(view.blocks, [bullet("x")])
        undo.manager.undo()  // "x"
        XCTAssertEqual(view.blocks, [bullet()])
        undo.manager.undo()  // the shortcut
        XCTAssertEqual(view.blocks, [NoteBlock(kind: .paragraph, runs: [.init(text: "-")])])
        undo.manager.undo()  // "-"
        XCTAssertEqual(view.blocks, [], "back to an empty plain note: nothing to save as \"- \"")
        undo.manager.redo()
        undo.manager.redo()
        XCTAssertEqual(view.blocks, [bullet()])
    }

    func testUndoOfDeletingEverythingBringsBackTextAndKind() {
        type("- ab")
        key { $0.deleteBackward(nil) }
        key { $0.deleteBackward(nil) }
        undo.manager.undo()
        XCTAssertEqual(view.blocks, [bullet("a")])
    }

    // MARK: Wrapping

    /// Every line fragment sits inside the visible, centred column at each width, for every indent.
    func testLongLinesWrapInsideTheColumnAtAnyWidth() {
        let long = String(repeating: "not the cleverest or most sophisticated solution, ", count: 6)
        view.load([NoteBlock(kind: .paragraph, runs: [.init(text: long)])]
                  + (0...NoteMarkdown.maxIndent).map { NoteBlock(kind: .bullet, indent: $0, runs: [.init(text: long)], byClaude: true) })
        for width in [400.0, 1_400, 0, 900, 40, 1_300, 300, 2_000, 760] as [CGFloat] {
            view.setFrameSize(NSSize(width: width, height: 600))
            guard width >= 2 * NoteStyle.gutter else { continue }  // a passing squeeze; only what can show counts
            let side = max(NoteStyle.gutter, (width - NoteStyle.maxColumn) / 2)
            XCTAssertEqual(view.textContainerInset.width, side, "inset at \(width)")
            let container = view.textContainer!
            XCTAssertEqual(container.size.width, width - 2 * side, accuracy: 0.5, "container at \(width)")
            let layout = view.layoutManager!
            layout.ensureLayout(for: container)
            var glyph = 0
            let glyphs = layout.numberOfGlyphs
            while glyph < glyphs {
                var range = NSRange()
                let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
                XCTAssertLessThanOrEqual(used.maxX + view.textContainerOrigin.x, width - side + 0.5, "line at \(width)")
                glyph = NSMaxRange(range)
            }
        }
    }

    /// In its scroll view the text is exactly as wide as what shows, however the scroll view is resized.
    func testTextViewMatchesTheVisibleWidthThroughResizes() {
        let scroll = NoteEditor.makeScrollView(for: view)
        view.load([NoteBlock(kind: .bullet, runs: [.init(text: String(repeating: "long words here ", count: 40))], byClaude: true)])
        for width in [1_300.0, 0, 820, 40, 1_600, 700, 1_300] as [CGFloat] {
            scroll.setFrameSize(NSSize(width: width, height: 700))
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.frame.width, scroll.contentSize.width, accuracy: 0.5, "text view at \(width)")
            XCTAssertEqual(view.textContainer!.size.width, max(view.frame.width - 2 * view.textContainerInset.width, 0),
                           accuracy: 0.5, "container at \(width)")
        }
    }

    // MARK: Blank lines

    private func paragraph(_ text: String) -> NoteBlock { NoteBlock(kind: .paragraph, runs: text.isEmpty ? [] : [.init(text: text)]) }

    private func lineHeightCap(at location: Int) -> CGFloat {
        (view.textStorage!.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.maximumLineHeight ?? 0
    }

    func testOneBlankLineBetweenTextIsASmallGap() {
        view.load([paragraph("one"), paragraph(""), paragraph("two")])
        XCTAssertEqual(lineHeightCap(at: 4), NoteStyle.blankLineHeight, "the blank line's own newline")
        XCTAssertEqual(lineHeightCap(at: 0), 0, "text lines keep their height")
        XCTAssertEqual(lineHeightCap(at: 5), 0)
    }

    func testSeveralBlankLinesOrAnEdgeBlankKeepFullHeight() {
        view.load([paragraph("one"), paragraph(""), paragraph(""), paragraph("two")])
        XCTAssertEqual(lineHeightCap(at: 4), 0)
        XCTAssertEqual(lineHeightCap(at: 5), 0)
        view.load([paragraph(""), paragraph("two")])
        XCTAssertEqual(lineHeightCap(at: 0), 0)
    }

    func testTypingIntoTheSmallBlankLineMakesNormalText() {
        view.load([paragraph("one"), paragraph(""), paragraph("two")])
        view.setSelectedRange(NSRange(location: 4, length: 0))
        type("x")
        XCTAssertEqual(view.blocks, [paragraph("one"), paragraph("x"), paragraph("two")])
        XCTAssertEqual(lineHeightCap(at: 4), 0)
        XCTAssertEqual(NoteMarkdown.render(view.blocks), "one\nx\ntwo")
    }

    func testBlankLinesStillRoundTrip() {
        let blocks = NoteMarkdown.parse("one\n\ntwo\n\n- three")
        view.load(blocks)
        XCTAssertEqual(NoteMarkdown.render(view.blocks), "one\n\ntwo\n\n- three")
    }

    func testTheCursorOnASmallParagraphGapIsFullHeight() {
        let gap = NSRect(x: 40, y: 100, width: 1, height: NoteStyle.blankLineHeight)
        let caret = NoteTextView.caretRect(gap)
        XCTAssertGreaterThanOrEqual(caret.height, NoteStyle.body.ascender - NoteStyle.body.descender)
        XCTAssertEqual(caret.midY, gap.midY, accuracy: 0.5)
        XCTAssertEqual(caret.minX, gap.minX)
    }

    func testTheCursorOnAnOrdinaryLineIsUnchanged() {
        let line = NSRect(x: 40, y: 100, width: 1, height: 22)
        XCTAssertEqual(NoteTextView.caretRect(line), line)
    }
}
