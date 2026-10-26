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
    @Published private(set) var starting = false
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
    private var stopWhenStarted = false
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
                if session?.target == user { stopRecording() }
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
        guard session == nil, !starting else { return }
        starting = true
        detector.isRecording = true
        lastError = nil
        let meeting = Meeting(title: title, appName: target?.appName ?? "In person",
                              bundleID: target.map(\.bundleID), startedAt: Date())
        Task {
            do {
                session = try await MeetingSession(meeting: meeting, target: target, paths: paths)
                recordingSince = meeting.startedAt
            } catch {
                detector.isRecording = false
                lastError = "Couldn't start recording: \(error)"
            }
            starting = false
            if stopWhenStarted { stopWhenStarted = false; stopRecording() }
        }
    }

    /// Stop button, the call ending, and sleep all land here: stop, then process in the background.
    func stopRecording() {
        guard !starting else { stopWhenStarted = true; return }
        guard let session else { return }
        self.session = nil
        recordingSince = nil
        detector.isRecording = false
        Task {
            let tracks = await session.stop()
            process(session.meeting, tracks: tracks, folder: session.folder, note: session.noteURL)
        }
    }

    /// On quit: only finalise the CAFs. Processing is left to crash recovery on the next launch.
    func stopForQuit() async {
        guard let session else { return }
        self.session = nil
        _ = await session.stop()
    }

    // MARK: processing

    private func process(_ meeting: Meeting, tracks: [TrackResult], folder: URL, note: URL) {
        processingCount += 1
        let processor = processor
        Task.detached {
            let result = await Result { try await processor.process(meeting: meeting, tracks: tracks, folder: folder, noteURL: note) }
            await self.finished(result, folder: folder)
        }
    }

    private func finished(_ result: Result<URL, Error>, folder: URL) {
        processingCount -= 1
        switch result {
        case .success(let note): lastNote = note
        case .failure(let error):
            lastError = "Processing \(folder.lastPathComponent) failed (will retry next launch): \(error)"
        }
    }

    /// Any folder with `.caf` files but no `transcript.json` was cut short by a crash or quit.
    private func recoverUnprocessed() {
        for folder in MeetingProcessor.pendingFolders(in: paths.recordingsRoot) {
            guard var meeting = try? Meeting.load(from: folder) else { continue }
            let note = paths.notesDir.appendingPathComponent(folder.lastPathComponent + ".md")
            // A note already there means a run died between note and transcript.json; never overwrite it.
            guard !FileManager.default.fileExists(atPath: note.path) else { continue }
            let cafs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "caf" }
            let tracks = cafs.compactMap { url -> TrackResult? in
                guard let kind = TrackKind(rawValue: url.deletingPathExtension().lastPathComponent) else { return nil }
                // Peak is unknown after a crash; don't claim silence we didn't measure.
                return TrackResult(kind: kind, url: url, seconds: 0, peakLevel: 1, error: nil)
            }
            guard !tracks.isEmpty else { continue }
            if meeting.endedAt == nil {
                meeting.endedAt = cafs.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
                meeting.warnings.append("Recovered after Lyra stopped unexpectedly — the end of the meeting may be missing.")
            }
            process(meeting, tracks: tracks, folder: folder, note: note)
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
