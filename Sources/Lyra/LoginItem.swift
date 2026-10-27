import AppKit
import ServiceManagement

/// Open at Login, through macOS's own login items: System Settings › General › Login Items lists Lyra too, and a
/// change made there shows here the next time Lyra comes forward. Works from /Applications, where Lyra is installed.
@MainActor
final class LoginItem: ObservableObject {
    enum State: Equatable {
        case on, off
        /// Registered, but macOS wants it allowed in System Settings › Login Items before it opens Lyra.
        case needsApproval

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .on
            case .requiresApproval: self = .needsApproval
            default: self = .off
            }
        }

        var isOn: Bool { self != .off }
    }

    @Published private(set) var state = State(SMAppService.mainApp.status)
    @Published private(set) var error: String?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func set(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
            error = nil
        } catch {
            NSLog("Lyra couldn't turn Open at Login \(on ? "on" : "off"): \(error)")
            self.error = "Couldn't turn Open at Login \(on ? "on" : "off"): \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() { state = State(SMAppService.mainApp.status) }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
