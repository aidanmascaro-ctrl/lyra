import AppKit
import SwiftUI

/// Non-activating prompt at the top-right, under the menu bar. Never steals focus from the call.
/// Auto-dismisses as Ignore after 60 s.
@MainActor
final class AllowPanel {
    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?

    /// `onAllowSlides` is Allow with slides switched on from the start.
    func show(app: String, title: String, onAllow: @escaping () -> Void, onAllowSlides: @escaping () -> Void,
              onIgnore: @escaping () -> Void, onAlwaysIgnore: @escaping () -> Void) {
        close()
        let view = AllowView(app: app, title: title,
                             allow: { [weak self] in self?.close(); onAllow() },
                             allowSlides: { [weak self] in self?.close(); onAllowSlides() },
                             ignore: { [weak self] in self?.close(); onIgnore() },
                             alwaysIgnore: { [weak self] in self?.close(); onAlwaysIgnore() })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 128),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: view)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 320 - 12, y: screen.maxY - 8))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, self?.panel != nil else { return }
            self?.close()
            onIgnore()
        }
    }

    func close() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct AllowView: View {
    let app: String
    let title: String
    let allow: () -> Void
    let allowSlides: () -> Void
    let ignore: () -> Void
    let alwaysIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("● \(app) meeting detected").font(.headline)
            if title != app { Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            HStack {
                Spacer()
                Button("Ignore", action: ignore)
                Button("Allow + slides", action: allowSlides).help("Record, and save the call's slides and shared screens")
                Button("Allow", action: allow).keyboardShortcut(.defaultAction)
            }
            Button("Always ignore \(app)", action: alwaysIgnore).lineLimit(1)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
