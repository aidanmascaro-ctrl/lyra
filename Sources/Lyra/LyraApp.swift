import AppKit
import SwiftUI

@main
struct LyraApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Aidan's Mac shows scroll bars always; Lyra's pages keep Granola's thin overlay scroller that shows only
        // while scrolling. Set for Lyra alone, in the volatile argument domain: nothing is saved.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuLabel(model: delegate.model).modifier(HomeOpener(presence: delegate.presence))
        }
        Window("Teach Lyra my voice", id: "enrol") { EnrolmentWindow(app: delegate.model) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        // The front door: opened at launch, from the Dock icon and from the menu's Open Lyra.
        Window("Lyra", id: "home") { HomeWindow(app: delegate.model) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 760, height: 760)
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
        Window("Meeting", id: "meeting") { MeetingWindow(app: delegate.model) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 820, height: 860)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let presence = DockPresence()

    func applicationDidFinishLaunching(_ notification: Notification) {
        presence.start()
        model.launch()
    }

    /// The Dock icon clicked, or Lyra opened again while running: home, in front.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let openHome = presence.openHome else { return true }  // not wired yet: AppKit's default
        openHome()
        return false
    }

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
