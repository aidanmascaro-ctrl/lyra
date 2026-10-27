import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Lyra") { show("home") }
        if let live = model.liveMeeting {
            Button("New note — \(live.appName)") {
                model.shownMeeting = live.folder
                show("meeting")
            }
        }
        Divider()
        if model.isRecording {
            Button("Stop recording") { model.stopRecording() }
        } else {
            Button("Start recording (in person)") { model.startInPerson() }.disabled(model.starting)
        }
        if model.processingCount > 0 { Text("Processing…") }
        Button("Teach Lyra my voice…") { show("enrol") }
        if !model.ignoredList.isEmpty {
            Menu("Ignored apps") {
                ForEach(model.ignoredList, id: \.key) { app in
                    Button(app.name) { model.stopIgnoring(app) }
                }
            }
        }
        if let error = model.lastError { Text(error).lineLimit(3) }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    /// A menu-bar-only app isn't active, so a new window would open behind everything else.
    private func show(_ id: String) {
        openWindow(id: id)
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
