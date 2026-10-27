import AppKit
import SwiftUI

@main
struct LyraApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuLabel(model: delegate.model)
        }
        Window("Teach Lyra my voice", id: "enrol") { EnrolmentWindow(app: delegate.model) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        Window("Meeting", id: "meeting") { MeetingWindow(app: delegate.model) }
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) { model.launch() }

    /// Quit while recording: finalise the CAFs first; the next launch processes them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording || model.starting else { return .terminateNow }
        Task {
            await model.stopForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
