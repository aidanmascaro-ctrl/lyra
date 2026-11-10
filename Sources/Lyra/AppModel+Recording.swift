import AppKit
import CoreGraphics
import LyraAudio
import LyraCore
import LyraSpeech

/// Recording: New note, Record, Pause/Resume, Stop, and stopping on quit.
extension AppModel {
    /// New note: a plain note with nothing recording. Its folder is reserved like a recording's, so Record can
    /// record into it later. Nil (with the reason in `lastError`) if the note couldn't be made.
    func newNote() -> URL? {
        var meeting = Meeting(title: "", appName: "In person", startedAt: Date())
        do {
            let (folder, note) = try paths.reserve(for: meeting, timeZone: .current)
            do {
                try MeetingProcessor.createSkeletonNote(for: meeting, recordingsFolder: folder, at: note)
                meeting.notePath = note.path
                try meeting.save(in: folder)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.removeItem(at: note)
                throw error
            }
            return folder
        } catch {
            lastError = ErrorBrief.sentence("Couldn't make a new note", error)
            return nil
        }
    }

    /// True when Record can start in this note: nothing else records, and the note isn't waiting to be written
    /// up (an unprocessed .caf) or being written up. Never recorded (New note) or ended and written up both qualify.
    func canRecord(in folder: URL) -> Bool {
        guard session == nil, state.phase == .idle, !isBusy(folder: folder, id: nil) else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains("meeting.json") && !names.contains { $0.hasSuffix(".caf") }
    }

    /// Start Recording in the menu-bar menu: New note then Record, without opening the window. Makes no note
    /// while something else records or starts.
    func recordNewNote() {
        guard session == nil, state.phase == .idle, let folder = newNote() else { return }
        record(in: folder)
    }

    /// Record (or Resume, after End) in a note: records into that note rather than a new one.
    func record(in folder: URL) {
        guard canRecord(in: folder) else { return }
        do {
            let meeting = try Meeting.load(from: folder)
            let note = meeting.notePath.map { URL(fileURLWithPath: $0) }
                ?? paths.notesDir.appendingPathComponent(folder.lastPathComponent + ".md")
            startRecording(target: nil, meeting: meeting, into: (folder, note))
        } catch {
            lastError = ErrorBrief.sentence("Couldn't start recording", error)
        }
    }

    func startRecording(target: MicUser?, title: String, slides: Bool = false) {
        let meeting = Meeting(title: title, appName: target?.appName ?? "In person",
                              bundleID: target.map(\.bundleID), startedAt: Date())
        startRecording(target: target, meeting: meeting, into: nil, slides: slides)
    }

    /// Slides on or off for the call being recorded (the bottom bar's Slides button).
    func setSlides(_ on: Bool) {
        guard let session, slides != nil else { return }
        session.setSlides(on)
        slides?.on = on
    }

    private func startRecording(target: MicUser?, meeting: Meeting, into existing: (folder: URL, note: URL)?, slides: Bool = false) {
        guard state.begin(target: target) else { return }
        detector.isRecording = true
        lastError = nil
        liveLines = []
        liveError = nil
        startingFolder = existing?.folder
        Task {
            defer { startingFolder = nil }
            do {
                let onLive: @MainActor ([LiveLine], String?) -> Void = { [weak self = self] lines, error in
                    self?.liveLines = lines
                    self?.liveError = error
                }
                let started = if let existing {
                    try await MeetingSession(recordingInto: existing.folder, noteURL: existing.note, meeting: meeting, onLive: onLive)
                } else {
                    try await MeetingSession(meeting: meeting, target: target, paths: paths, onLive: onLive)
                }
                session = started
                if started.target != nil {
                    self.slides = CallSlides(on: false, count: 0)
                    started.onSlideSaved = { [weak self] count in self?.slides?.count = count }
                    if slides { setSlides(true) }
                }
                recordingSince = Date()
                pausedSince = nil
                pausedBefore = 0
                liveMeeting = LiveMeeting(folder: started.folder, appName: meeting.appName, title: meeting.title)
                // The call ended (or Stop was clicked) while we were still starting.
                if state.started() { stopSession() }
            } catch {
                state.failed()
                detector.isRecording = false
                lastError = ErrorBrief.sentence("Couldn't start recording", error)
            }
        }
    }

    /// Pause: the mic and call audio are let go until Resume.
    /// If the call audio or mic can't be let go of, the recording is ended rather than claim a pause it isn't.
    func pauseRecording() {
        guard let session, state.pause() else { return }
        pausedSince = Date()
        do { try session.pause() } catch {
            lastError = ErrorBrief.sentence("Couldn't pause recording, so it was ended", error)
            if state.requestStop() { stopSession() }
        }
    }

    /// Resume carries on in the same recording. If the mic won't restart, the recording ends there and is written up.
    func resumeRecording() {
        guard let session, state.resume() else { return }
        pausedBefore += pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        pausedSince = nil
        do { try session.resume() } catch {
            lastError = ErrorBrief.sentence("Couldn't resume recording, so it was ended", error)
            if state.requestStop() { stopSession() }
        }
    }

    /// Stop button and sleep land here; a stop during the start window is applied once recording runs.
    func stopRecording() {
        if state.requestStop() { stopSession() }
    }

    /// Stops the running session and processes it in the background.
    func stopSession() {
        guard let session else { return }
        self.session = nil
        recordingSince = nil
        pausedSince = nil
        pausedBefore = 0
        liveMeeting = nil
        slides = nil
        liveLines = []  // the live draft is thrown away; the full transcript comes from processing
        liveError = nil
        detector.isRecording = false
        Task {
            let tracks = await session.stop()
            run([(session.meeting, tracks, session.folder, session.noteURL)])
        }
    }

    /// On quit: only finalise the CAFs. Processing is left to crash recovery on the next launch.
    func stopForQuit() async {
        while starting { try? await Task.sleep(for: .milliseconds(100)) }  // let a start finish (≤ ~3 s), then stop it
        guard state.requestStop(), let session else { return }
        self.session = nil
        _ = await session.stop()
    }
}
