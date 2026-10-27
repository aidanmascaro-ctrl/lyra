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

    /// `LYRA_DEBUG_OPEN`: a meeting folder to show. `LYRA_DEBUG_WIDTH` / `LYRA_DEBUG_HEIGHT`: the window's size;
    /// the width may be a comma-separated list, applied half a second apart, to try a series of resizes.
    static func apply(to model: AppModel) {
        if let folder = env["LYRA_DEBUG_OPEN"] { model.route = .meeting(URL(fileURLWithPath: folder, isDirectory: true)) }
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
