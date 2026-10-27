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
}
