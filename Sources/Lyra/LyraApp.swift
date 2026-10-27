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
            MenuLabel(model: delegate.model).modifier(MainWindowOpener(presence: delegate.presence))
        }
        Window("Teach Lyra my voice", id: "enrol") { EnrolmentWindow(app: delegate.model) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        // The one window: home, or a meeting opened from it. Opened at launch, from the Dock icon and from the menu.
        Window("Lyra", id: MainWindow.id) { MainWindow(app: delegate.model).modifier(MainWindowOpener(presence: delegate.presence)) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 820, height: 860)
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var presence = DockPresence(app: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        presence.start()
        model.launch()
    }

    /// The Dock icon clicked, or Lyra opened again while running: Lyra's windows forward (minimised ones restored),
    /// or the main window on home when none is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presence.reopen()
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
