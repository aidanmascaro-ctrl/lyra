import AppKit
import LyraCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Lyra") { show(.home) }
        // Stop also covers the few seconds a recording takes to start; the stop is applied once it runs.
        if model.isRecording || model.starting {
            Button("Stop Recording") { model.stopRecording() }
        } else {
            Button("Start Recording") { model.recordNewNote() }
        }
        if let live = model.liveMeeting {
            Button("New note — \(live.appName)") { show(.meeting(live.folder)) }
        }
        Divider()
        if model.isRecording {
            if model.isPaused {
                Button("Resume recording") { model.resumeRecording() }
            } else {
                Button("Pause recording") { model.pauseRecording() }
            }
        }
        if model.processingCount > 0 { Text("Processing…") }
        if !model.ignoredList.isEmpty {
            Menu("Ignored apps") {
                ForEach(model.ignoredList, id: \.key) { app in
                    Button(app.name) { model.stopIgnoring(app) }
                }
            }
        }
        if let error = model.lastError { Text(ErrorBrief.menuLine(error)).lineLimit(1) }
        Divider()
        Toggle("Open at Login", isOn: Binding(get: { loginItem.state.isOn }, set: loginItem.set))
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
            Text("\(model.isPaused ? "⏸" : "🔴") \(model.elapsed)").monospacedDigit()
        } else {
            Image(systemName: "waveform")
        }
    }
}
