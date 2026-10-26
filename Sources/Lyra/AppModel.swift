import AppKit
import CoreGraphics
import LyraAudio
import LyraCore
import LyraSpeech

/// Owns the whole flow: detect → prompt → record → process → note. All state lives on the main actor;
/// the detector is only touched here. Transcription runs detached, off the main actor.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var recordingSince: Date?
    @Published private(set) var state = RecordingState()
    @Published private(set) var processingCount = 0
    @Published private(set) var lastNote: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var now = Date()

    private let paths = MeetingPaths(recordingsRoot: MeetingPaths.defaultRecordingsRoot, notesDir: MeetingPaths.defaultNotesDir)
    // One transcriber for the app's lifetime: it loads its models once.
    private let processor = MeetingProcessor(
        trackTranscriber: TrackTranscriber(diarizer: FluidDiarizer(), transcriber: FluidTranscriber()),
        loader: { try AudioLoader.load16kMono(url: $0) },
        convert: M4AConverter.convert)
    private let micUsage = CoreAudioMicUsage()
    private let detector = MeetingDetector(ownPID: ProcessInfo.processInfo.processIdentifier,
                                           ignoredBundleIDs: [Bundle.main.bundleIdentifier ?? "au.aidos.lyra"])
    private let panel = AllowPanel()
    private var session: MeetingSession?
    private var prompted: MicUser?
    private var poller: Task<Void, Never>?

    func launch() {
        recoverUnprocessed()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    var isRecording: Bool { session != nil }
    var starting: Bool { if case .starting = state.phase { true } else { false } }

    var elapsed: String {
        let s = Int(now.timeIntervalSince(recordingSince ?? now))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: detection

    private func tick() {
        now = Date()
        for event in detector.update(users: micUsage.currentMicUsers(), now: now) {
            switch event {
            case .meetingStarted(let user):
                prompted = user
                let title = Self.windowTitle(for: user)
                panel.show(app: user.appName, title: title,
                           onAllow: { [weak self] in self?.prompted = nil; self?.startRecording(target: user, title: title) },
                           onIgnore: { [weak self] in self?.prompted = nil })
            case .meetingEnded(let user):
                if prompted == user { panel.close(); prompted = nil }
                if state.meetingEnded(user) { stopSession() }
            }
        }
    }

    /// Front window title of the meeting app (needs Screen Recording permission), else the app name.
    static func windowTitle(for user: MicUser) -> String {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let title = windows.first { w in
            (w[kCGWindowLayer as String] as? Int) == 0
                && ((w[kCGWindowOwnerPID as String] as? pid_t) == user.pid || (w[kCGWindowOwnerName as String] as? String) == user.appName)
                && !((w[kCGWindowName as String] as? String) ?? "").isEmpty
        }?[kCGWindowName as String] as? String
        return title ?? user.appName
    }

    // MARK: recording

    func startInPerson() { startRecording(target: nil, title: "In-person meeting") }

    private func startRecording(target: MicUser?, title: String) {
        guard state.begin(target: target) else { return }
        detector.isRecording = true
        lastError = nil
        let meeting = Meeting(title: title, appName: target?.appName ?? "In person",
                              bundleID: target.map(\.bundleID), startedAt: Date())
        Task {
            do {
                let started = try await MeetingSession(meeting: meeting, target: target, paths: paths)
                session = started
                recordingSince = meeting.startedAt
                // The call ended (or Stop was clicked) while we were still starting.
                if state.started() { stopSession() }
            } catch {
                state.failed()
                detector.isRecording = false
                lastError = "Couldn't start recording: \(error)"
            }
        }
    }

    /// Stop button and sleep land here; a stop during the start window is applied once recording runs.
    func stopRecording() {
        if state.requestStop() { stopSession() }
    }

    /// Stops the running session and processes it in the background.
    private func stopSession() {
        guard let session else { return }
        self.session = nil
        recordingSince = nil
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

    // MARK: processing

    private typealias Job = (meeting: Meeting, tracks: [TrackResult], folder: URL, note: URL)

    /// Processes jobs one at a time, off the main actor; each result hops back here.
    private func run(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        processingCount += jobs.count
        let processor = processor
        Task.detached {
            for job in jobs {
                let result = await Result { try await processor.process(meeting: job.meeting, tracks: job.tracks, folder: job.folder, noteURL: job.note) }
                await self.finished(result, folder: job.folder)
            }
        }
    }

    private func finished(_ result: Result<URL, Error>, folder: URL) {
        processingCount -= 1
        switch result {
        case .success(let note): lastNote = note
        case .failure(let error): report("Processing \(folder.lastPathComponent) failed (will retry next launch): \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        lastError = [lastError, message].compactMap { $0 }.joined(separator: "\n")
    }

    /// Any folder with `.caf` files but no `transcript.json` was cut short by a crash or quit.
    /// A folder that can't be recovered is reported, never skipped silently.
    private func recoverUnprocessed() {
        var jobs: [Job] = []
        for folder in MeetingProcessor.pendingFolders(in: paths.recordingsRoot) {
            do {
                let job = try MeetingProcessor.recoveryJob(folder: folder, notesDir: paths.notesDir)
                jobs.append((job.meeting, job.tracks, folder, job.note))
            } catch {
                report("Couldn't recover \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        run(jobs)
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
