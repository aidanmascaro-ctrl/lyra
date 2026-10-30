import AppKit
import SwiftUI

/// Lyra's one window, Granola-style: home, a meeting or a folder, with the sidebar down the left when it shows.
/// Opening a meeting never makes a second window; the pill by the traffic lights (or ⌘[) goes back to home.
struct MainWindow: View {
    static let id = "main"
    @ObservedObject var app: AppModel
    @ObservedObject private var sidebar: SidebarModel

    init(app: AppModel) {
        self.app = app
        sidebar = app.sidebar
    }

    /// Home ⇄ meeting: the page going away fades out quickly, then the new one fades in and eases the last few
    /// points sideways into place (from the right opening a meeting, from the left going home). The two never show
    /// at once, so their titles don't cross-fade over each other.
    private static let pageAnimation = Animation.easeInOut(duration: 0.28)
    private static let fadeOut = Animation.easeIn(duration: 0.12)
    private static let fadeIn = Animation.easeOut(duration: 0.24).delay(0.12)
    private static let pageShift: CGFloat = 16
    /// Narrower than this, the sidebar lies over the page instead of narrowing it.
    private static let overlayBelow: CGFloat = 760

    var body: some View {
        GeometryReader { window in
            let overlays = window.size.width < Self.overlayBelow
            HStack(spacing: 0) {
                if sidebar.visible && !overlays { sidebarView }
                pages
            }
            .overlay(alignment: .leading) { if sidebar.visible && overlays { overlaySidebar } }
        }
        .animation(SidebarModel.spring, value: sidebar.visible)
        .overlay(alignment: .top) { TitleBarStrip().frame(height: Chrome.topInset).ignoresSafeArea() }
        .overlay(alignment: .topLeading) {
            TitleBarPills(sidebar: sidebar, showsBack: app.route != .home) { app.route = .home }
        }
        .frame(minWidth: 560, minHeight: 480)
        .lyraWindow()
    }

    private var pages: some View {
        ZStack {
            switch app.route {
            case .home:
                HomePage(app: app).transition(page(from: -Self.pageShift))
            case .meeting(let folder):
                MeetingPage(folder: folder, app: app).transition(page(from: Self.pageShift))
            case .folder(let name):
                FolderPage(name: name, app: app, sidebar: sidebar).transition(page(from: Self.pageShift))
            }
        }
        .animation(Self.pageAnimation, value: app.route)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarView: some View {
        Sidebar(app: app, model: sidebar).transition(.move(edge: .leading))
    }

    /// In a narrow window: over the page, with a light shade behind it that closes it when clicked.
    private var overlaySidebar: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture(perform: sidebar.hide).transition(.opacity)
            sidebarView.shadow(color: .black.opacity(0.25), radius: 12)
        }
    }

    private func page(from shift: CGFloat) -> AnyTransition {
        .asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(x: shift)).animation(Self.fadeIn),
                    removal: AnyTransition.opacity.animation(Self.fadeOut))
    }
}
