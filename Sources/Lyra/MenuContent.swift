import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isRecording {
            Button("Stop recording") { model.stopRecording() }
        } else {
            Button("Start recording (in person)") { model.startInPerson() }.disabled(model.starting)
        }
        if model.processingCount > 0 { Text("Processing…") }
        if let note = model.lastNote {
            Button("Open last note") { NSWorkspace.shared.open(note) }
        }
        if let error = model.lastError { Text(error).lineLimit(3) }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
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
