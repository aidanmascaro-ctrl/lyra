import AppKit
import SwiftUI

/// Lyra's one window, Granola-style: home, or a meeting opened from it. Opening a meeting never makes a second
/// window; the pill by the traffic lights (or ⌘[) goes back to home.
struct MainWindow: View {
    static let id = "main"
    @ObservedObject var app: AppModel

    /// Home ⇄ meeting: the page going away fades out quickly, then the new one fades in and eases the last few
    /// points sideways into place (from the right opening a meeting, from the left going home). The two never show
    /// at once, so their titles don't cross-fade over each other.
    private static let pageAnimation = Animation.easeInOut(duration: 0.28)
    private static let fadeOut = Animation.easeIn(duration: 0.12)
    private static let fadeIn = Animation.easeOut(duration: 0.24).delay(0.12)
    private static let pageShift: CGFloat = 16

    var body: some View {
        ZStack {
            switch app.route {
            case .home:
                HomePage(app: app).transition(page(from: -Self.pageShift))
            case .meeting(let folder):
                MeetingPage(folder: folder, app: app).transition(page(from: Self.pageShift))
            }
        }
        .animation(Self.pageAnimation, value: app.route)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { TitleBarStrip().frame(height: Chrome.topInset).ignoresSafeArea() }
        .overlay(alignment: .topLeading) {
            if app.route != .home { BackPill { app.route = .home } }
        }
        .frame(minWidth: 560, minHeight: 480)
        .lyraWindow()
    }

    private func page(from shift: CGFloat) -> AnyTransition {
        .asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(x: shift)).animation(Self.fadeIn),
                    removal: AnyTransition.opacity.animation(Self.fadeOut))
    }
}

/// "‹ ⌂" in a quiet rounded pill, in the title bar just right of the traffic lights.
private struct BackPill: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Image(systemName: "house").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(hovering ? Chrome.pill.opacity(1.6) : Chrome.pill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to home (⌘[)")
        .onHover { hovering = $0 }
        .padding(.leading, 76).padding(.top, 3)
        .ignoresSafeArea()
    }
}
