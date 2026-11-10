import AppKit
import LyraCore
import XCTest
@testable import Lyra

/// The note's top padding stays in view when the window is resized with the note scrolled to the top.
@MainActor
final class NoteScrollTests: XCTestCase {
    private func longNote() -> [NoteBlock] {
        (0..<60).map { NoteBlock(kind: .paragraph, runs: [.init(text: "Line \($0) " + String(repeating: "some words ", count: 12))]) }
    }

    func testResizingAtTheTopKeepsTheTopPaddingInView() {
        let view = NoteTextView()
        let scroll = NoteEditor.makeScrollView(for: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.contentView = scroll
        view.load(longNote())
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        for width in [700.0, 1_300, 420, 1_000, 900] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 700))
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "scrolled after resizing to \(width)")
        }
    }

    func testResizingPartWayDownDoesNotJumpToTheTop() {
        let view = NoteTextView()
        let scroll = NoteEditor.makeScrollView(for: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.contentView = scroll
        view.load(longNote())
        scroll.layoutSubtreeIfNeeded()
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 600, accuracy: 0.5, "set-up: text view is \(view.frame.height) tall")
        window.setContentSize(NSSize(width: 420, height: 700))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100)
    }
}
