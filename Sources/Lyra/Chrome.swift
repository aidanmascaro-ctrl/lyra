import AppKit
import SwiftUI

/// Lyra's Granola look: one flat page colour from the title bar down, quiet pills and floating capsules.
enum Chrome {
    static let page = Color(nsColor: NoteStyle.background)
    /// The floating bottom capsules: a step lighter than the page in dark, white on a light page.
    static let capsule = Color(nsColor: dynamic(dark: NSColor(white: 0.21, alpha: 1), light: .white))
    static let capsuleStroke = Color(nsColor: dynamic(dark: NSColor(white: 1, alpha: 0.09), light: NSColor(white: 0, alpha: 0.10)))
    static let pill = Color(nsColor: dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.05)))
    static let hover = Color(nsColor: dynamic(dark: NSColor(white: 1, alpha: 0.05), light: NSColor(white: 0, alpha: 0.04)))
    static let live = Color(red: 0.30, green: 0.80, blue: 0.45)
    static let record = Color(red: 0.92, green: 0.30, blue: 0.27)
    static let titleFont = Font.system(size: 28, weight: .regular, design: .serif)
    /// Room for the floating traffic lights above the first line.
    static let topInset: CGFloat = 44

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

extension View {
    /// The same centred column as the note editor's text, so headers line up with the first letter of the notes.
    func noteColumn() -> some View {
        frame(maxWidth: NoteStyle.maxColumn - 10, alignment: .leading)
            .padding(.horizontal, NoteStyle.gutter + 5)
            .frame(maxWidth: .infinity)
    }

    /// Transparent title bar with no title, content under it, the page colour behind everything.
    func lyraWindow() -> some View {
        background(WindowChrome()).background(Chrome.page.ignoresSafeArea())
    }

    func capsuleSurface() -> some View {
        background(Capsule().fill(Chrome.capsule))
            .overlay(Capsule().strokeBorder(Chrome.capsuleStroke))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

/// A small rounded label in the meta row under the title.
struct Pill<Label: View>: View {
    @ViewBuilder var label: () -> Label

    var body: some View {
        label()
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Chrome.pill))
    }
}

/// Sets the hosting window's chrome once it is in a window.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NoteStyle.background
            window.isMovableByWindowBackground = false
        }
    }
}
