import SwiftUI

/// The quiet pills in the title bar just right of the traffic lights: the sidebar button, then (off home) back.
struct TitleBarPills: View {
    @ObservedObject var sidebar: SidebarModel
    let showsBack: Bool
    let back: () -> Void

    /// Room the traffic lights take.
    private static let trafficLights: CGFloat = 76

    var body: some View {
        HStack(spacing: 6) {
            TitleBarPill(action: sidebar.toggle, help: sidebar.visible ? "Hide sidebar (⌘\\)" : "Show sidebar (⌘\\)") {
                Image(systemName: "sidebar.left").font(.system(size: 12, weight: .medium))
            }
            if showsBack {
                TitleBarPill(action: back, help: "Back to home (⌘[)", shortcut: KeyboardShortcut("[", modifiers: .command)) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Image(systemName: "house").font(.system(size: 11, weight: .medium))
                    }
                }
            }
        }
        .padding(.leading, Self.trafficLights).padding(.top, 3)
        .ignoresSafeArea()
    }
}

/// One rounded pill that lights up a little under the pointer.
private struct TitleBarPill<Label: View>: View {
    let action: () -> Void
    let help: String
    var shortcut: KeyboardShortcut?
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(hovering ? Chrome.pill.opacity(1.6) : Chrome.pill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .help(help)
        .onHover { hovering = $0 }
    }
}
