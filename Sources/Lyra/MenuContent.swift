import AppKit
import LyraCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Lyra") { show(.home) }
        if let live = model.liveMeeting {
            Button("New note — \(live.appName)") { show(.meeting(live.folder)) }
        }
        Divider()
        if model.isRecording {
            Button("Stop recording") { model.stopRecording() }
        } else {
            Button("Start recording (in person)") { model.startInPerson() }.disabled(model.starting)
        }
        if model.processingCount > 0 { Text("Processing…") }
        Button("Teach Lyra my voice…") {
            openWindow(id: "enrol")
            NSApp.activate()
        }
        if !model.ignoredList.isEmpty {
            Menu("Ignored apps") {
                ForEach(model.ignoredList, id: \.key) { app in
                    Button(app.name) { model.stopIgnoring(app) }
                }
            }
        }
        if let error = model.lastError { Text(ErrorBrief.menuLine(error)).lineLimit(1) }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    /// Lyra's one window, showing `route`. A menu-bar-only app isn't active, so it is activated too, or the window
    /// would open behind everything else.
    private func show(_ route: Route) {
        model.route = route
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isRecording {
            Text("🔴 \(model.elapsed)").monospacedDigit()
        } else {
            Image(systemName: "waveform")
        }
    }
}
