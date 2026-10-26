import SwiftUI

@main
struct LyraApp: App {
    var body: some Scene {
        MenuBarExtra("Lyra", systemImage: "waveform") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
