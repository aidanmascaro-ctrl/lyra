import AppKit
import CoreGraphics
import LyraAudio
import LyraCore
import LyraSpeech

/// Meeting detection: the once-a-second tick that spots a call taking the mic, and the Allow panel it shows.
extension AppModel {
    func tick() {
        now = Date()
        if let join = pendingJoin, !join.isOpen(at: now) { pendingJoin = nil }
        for event in detector.update(users: micUsage.currentMicUsers(), now: now) {
            switch event {
            case .meetingStarted(let user):
                // Aidan pressed Join in Lyra and the call's app now has the mic: he's in, so record (once, without asking).
                let owner = CoreAudioMicUsage.owningApp(of: user.pid)?.bundleIdentifier ?? ""
                if let title = pendingJoin?.claim(now: now, bundleIDs: [user.bundleID, owner]) {
                    pendingJoin = nil
                    startRecording(target: user, title: title)
                    continue
                }
                prompted = user
                let title = Self.windowTitle(for: user)
                let allow: (Bool) -> Void = { [weak self] slides in
                    self?.prompted = nil
                    // Read again: the user may have switched tabs while the prompt showed.
                    self?.startRecording(target: user, title: Self.windowTitle(for: user), slides: slides)
                    Self.askForWindowTitlesOnce()
                }
                panel.show(app: user.appName, title: title,
                           onAllow: { allow(false) },
                           onAllowSlides: { allow(true) },
                           // Also the 60 s timeout. Frees the detector so other apps can still prompt.
                           onIgnore: { [weak self] in self?.prompted = nil; self?.detector.dismiss() },
                           onAlwaysIgnore: { [weak self] in
                               guard let self else { return }
                               ignoredApps.add(IgnoredApp(user: user))
                               ignoredList = ignoredApps.all()
                               prompted = nil
                               detector.dismiss()
                           })
            case .meetingEnded(let user):
                if prompted == user { panel.close(); prompted = nil }
                if state.meetingEnded(user) { stopSession() }
            }
        }
    }

    /// Front window title of the app owning the meeting process (Chrome, not its audio helper), without the
    /// browser suffix; else the app name. Window names need the Screen Recording permission.
    static func windowTitle(for user: MicUser) -> String {
        let owner = CoreAudioMicUsage.owningApp(of: user.pid)?.processIdentifier ?? user.pid
        // Front-to-back order, so the first match is the app's frontmost window.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let name = windows.first { w in
            (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowOwnerPID as String] as? pid_t) == owner
                && !((w[kCGWindowName as String] as? String) ?? "").isEmpty
        }?[kCGWindowName as String] as? String
        return Meeting.title(window: name, appName: user.appName)
    }

    /// Asks for Screen Recording (which unlocks window titles) the first time it is missing at Allow, and
    /// never again. Called after recording has started: the system prompt must not hold it up.
    static func askForWindowTitlesOnce() {
        let key = "askedScreenCaptureAccess"
        guard !CGPreflightScreenCaptureAccess(), !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        CGRequestScreenCaptureAccess()
    }
}
