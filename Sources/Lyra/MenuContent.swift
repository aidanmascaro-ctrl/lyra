import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRecording {
            Button("Stop recording") { model.stopRecording() }
        } else {
            Button("Start recording (in person)") { model.startInPerson() }.disabled(model.starting)
        }
        if model.processingCount > 0 { Text("Processing…") }
        if let meeting = model.lastMeeting {
            Button("Open last meeting") {
                model.shownMeeting = meeting
                show("meeting")
            }
        }
        Button("Teach Lyra my voice…") { show("enrol") }
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
