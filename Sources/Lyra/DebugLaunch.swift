#if DEBUG
import AppKit

/// Debug builds only: open a meeting, pick its tab and size the window from the environment, so a change can be
/// looked at in Lyra's own window (with `LYRA_NOTES_DIR` / `LYRA_RECORDINGS_DIR` on scratch copies) without
/// clicking anything. Release builds have none of this.
@MainActor
enum DebugLaunch {
    private static let env = ProcessInfo.processInfo.environment

    /// `LYRA_DEBUG_TAB`: "mynotes", "expanded" or "transcript".
    static var tab: MeetingTab? {
        switch env["LYRA_DEBUG_TAB"] {
        case "mynotes": .myNotes
        case "expanded": .expanded
        case "transcript": .transcript
        default: nil
        }
    }

    /// `LYRA_DEBUG_PANEL=1`: the meeting opens with its transcript panel up.
    static var panelOpen: Bool { env["LYRA_DEBUG_PANEL"] == "1" }

    /// `LYRA_DEBUG_TAGS=1`: the note's tags start unfolded.
    static var tagsOpen: Bool { env["LYRA_DEBUG_TAGS"] == "1" }

    /// `LYRA_DEBUG_PEOPLE=1`: the people pill starts laid out, one pill per name.
    static var peopleOpen: Bool { env["LYRA_DEBUG_PEOPLE"] == "1" }

    /// `LYRA_DEBUG_TARGET`: a sidebar folder drawn as if a meeting were being dragged over it.
    static var dropTarget: String? { env["LYRA_DEBUG_TARGET"] }

    /// `LYRA_DEBUG_SIDEBAR` (1: shown, 0: hidden), `LYRA_DEBUG_FOLDER` (that folder's page),
    /// `LYRA_DEBUG_EXPAND` (that folder opened in the sidebar).
    private static func applySidebar(to model: AppModel) {
        let sidebar = model.sidebar
        switch env["LYRA_DEBUG_SIDEBAR"] {
        case "1" where !sidebar.visible: sidebar.toggle()
        case "0" where sidebar.visible: sidebar.hide()
        default: break
        }
        if let name = env["LYRA_DEBUG_FOLDER"] { model.route = .folder(name) }
        if let name = env["LYRA_DEBUG_EXPAND"] { sidebar.expanded.insert(name) }
    }

    /// `LYRA_DEBUG_OPEN`: a meeting folder to show. `LYRA_DEBUG_WIDTH` / `LYRA_DEBUG_HEIGHT`: the window's size;
    /// the width may be a comma-separated list, applied half a second apart, to try a series of resizes.
    static func apply(to model: AppModel) {
        applySidebar(to: model)
        if let folder = env["LYRA_DEBUG_OPEN"] {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            model.route = .meeting(url)
            // `LYRA_DEBUG_LIVE_SLIDES`: show it as a call being recorded, with this many slides saved (0: Slides off).
            if let slides = env["LYRA_DEBUG_LIVE_SLIDES"].flatMap({ Int($0) }) { model.debugShowLiveCall(folder: url, slides: slides) }
        }
        if env["LYRA_DEBUG_ALLOW"] == "1" { model.debugShowAllowPanel() }  // `LYRA_DEBUG_ALLOW=1`: the Allow panel
        // `LYRA_DEBUG_SETTINGS=1`: the Settings window, as Lyra › Settings… opens it.
        if env["LYRA_DEBUG_SETTINGS"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
                menu.performActionForItem(at: index)
            }
        }
        let widths = (env["LYRA_DEBUG_WIDTH"] ?? "").split(separator: ",").compactMap { Double($0) }
        let height = env["LYRA_DEBUG_HEIGHT"].flatMap(Double.init) ?? 860
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for width in widths {
                for window in NSApp.windows where window.isVisible && window.title == "Lyra" {
                    window.setFrame(NSRect(x: 80, y: 80, width: width, height: height), display: true)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
#endif
