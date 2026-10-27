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
    /// When the running recording was paused; nil while it records.
    @Published private(set) var pausedSince: Date?
    /// Paused time before the current pause, left out of the elapsed time.
    private var pausedBefore: TimeInterval = 0
    /// The note Record was pressed in, while its recording starts.
    @Published private(set) var startingFolder: URL?
    @Published private(set) var state = RecordingState()
    @Published private(set) var processingCount = 0
    /// Goes up whenever processing or the after-meeting step finishes a meeting, so open windows re-read it.
    @Published private(set) var revision = 0
    /// The meeting being recorded now, for New note.
    @Published private(set) var liveMeeting: LiveMeeting?
    /// What Lyra's one window shows: home, or a meeting.
    @Published var route: Route = .home
    @Published private(set) var lastError: String?
    @Published private(set) var now = Date()
    /// Apps the user chose to never be prompted about; mirrors the saved list so the menu refreshes.
    @Published private(set) var ignoredList: [IgnoredApp] = []
    /// Claude's Expanded section as it streams in, by meeting id; gone once it is saved in the note.
    @Published private(set) var liveExpansion: [UUID: [NoteBlock]] = [:]
    /// The rough live transcript of the meeting being recorded; thrown away when it stops.
    @Published private(set) var liveLines: [LiveLine] = []
    /// Set when live transcription gives up mid-meeting; the recording carries on regardless.
    @Published private(set) var liveError: String?
    /// Join was pressed on a meeting about to start: for a short while, the next meeting app to take the mic records
    /// without asking. Shown on home with a way to call it off.
    @Published var pendingJoin: PendingJoin?
    /// Slides for the call being recorded: nil when nothing records or the recording has no call window.
    @Published private(set) var slides: CallSlides?

    let paths = MeetingPaths(recordingsRoot: AppModel.recordingsRoot, notesDir: AppModel.notesRoot)
    /// Notes are found by `lyra_id` anywhere under Meetings/; links are rewritten across the whole vault.
    let notes = NoteIndex(notesRoot: AppModel.notesRoot, vaultRoot: AppModel.notesRoot.deletingLastPathComponent())
    /// For Claude's in-window actions (Expand this, Ask, add an idea).
    let expander = Expander(claude: ClaudeCLI())

    /// `LYRA_RECORDINGS_DIR` / `LYRA_NOTES_DIR` / `LYRA_PEOPLE_FILE` point Lyra at scratch copies, for trying
    /// changes without touching the real recordings, vault or voices.
    private static let recordingsRoot = ProcessInfo.processInfo.environment["LYRA_RECORDINGS_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MeetingPaths.defaultRecordingsRoot
    private static let notesRoot = ProcessInfo.processInfo.environment["LYRA_NOTES_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MeetingPaths.defaultNotesDir
    /// The one people store: processing, enrolment and renames all share it, so a new voice is used by the next meeting.
    /// An unreadable store loads as nobody (naming finds no one) and refuses writes with a plain-English error.
    let people = PeopleStore(fileURL: ProcessInfo.processInfo.environment["LYRA_PEOPLE_FILE"]
        .map { URL(fileURLWithPath: $0) } ?? PeopleStore.defaultURL)
    // One transcriber for the app's lifetime: it loads its models once.
    private lazy var processor: MeetingProcessor = { [people] in
        MeetingProcessor(
            trackTranscriber: TrackTranscriber(diarizer: FluidDiarizer(), transcriber: FluidTranscriber()),
            loader: { try AudioLoader.load16kMono(url: $0) },
            convert: M4AConverter.convert,
            people: { people.all() },
            learn: { name, sample in try people.learn(name: name, sample: sample) })
    }()
    private lazy var afterMeeting: AfterMeeting = { [notes] in
        let claude = ClaudeCLI()
        return AfterMeeting(index: notes, claude: claude, expander: Expander(claude: claude), vaultRoot: notes.vaultRoot)
    }()
    /// The tail of the background queue: processing and after-meeting work run one at a time, in order.
    private var pipeline: Task<Void, Never>?
    /// Meeting folders with processing, expansion or re-expansion queued or running (count per folder path).
    private var busyFolders: [String: Int] = [:]
    private let micUsage = CoreAudioMicUsage()
    private let ignoredApps = IgnoredApps(defaults: .standard)
    private let detector: MeetingDetector
    fileprivate let panel = AllowPanel()
    private var session: MeetingSession?
    private var prompted: MicUser?
    private var poller: Task<Void, Never>?

    init() {
        let ignoredApps = ignoredApps
        let ownBundleID = Bundle.main.bundleIdentifier ?? "au.aidos.lyra"
        detector = MeetingDetector(ownPID: ProcessInfo.processInfo.processIdentifier,
                                   ignore: { $0.bundleID == ownBundleID || ignoredApps.contains($0) })
        ignoredList = ignoredApps.all()
    }

    func stopIgnoring(_ app: IgnoredApp) {
        ignoredApps.remove(app)
        ignoredList = ignoredApps.all()
    }

    func launch() {
        upgradeNoteLayouts()
        recoverUnprocessed()
        // Processed, but Lyra quit before titles and expansion were done: finish them (after any recovery above).
        for folder in AfterMeeting.pendingFolders(in: paths.recordingsRoot) { runAfterMeeting(folder: folder) }
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

    /// Notes written in an older layout are brought to the current one once, off the main actor.
    private func upgradeNoteLayouts() {
        let notes = notes
        Task.detached { [weak self] in
            let problems = NoteLayoutUpgrade.run(index: notes)
            guard !problems.isEmpty else { return }
            await MainActor.run { self?.lastError = problems.joined(separator: "\n") }
        }
    }

    var isRecording: Bool { session != nil }
    var starting: Bool { if case .starting = state.phase { true } else { false } }
    var isPaused: Bool { if case .paused = state.phase { true } else { false } }
    /// How loud the recording is now, for the bars; read every frame, so not published.
    var level: Float { session?.level ?? 0 }

    /// Recorded time so far: paused time doesn't count.
    var elapsed: String {
        let paused = pausedBefore + (pausedSince.map { now.timeIntervalSince($0) } ?? 0)
        let s = max(0, Int(now.timeIntervalSince(recordingSince ?? now) - paused))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: detection

    private func tick() {
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

    // MARK: recording

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

    private func startRecording(target: MicUser?, title: String, slides: Bool = false) {
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
                liveMeeting = LiveMeeting(folder: started.folder, appName: meeting.appName)
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
    private func stopSession() {
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

    // MARK: processing

    private typealias Job = (meeting: Meeting, tracks: [TrackResult], folder: URL, note: URL)

    /// Processes jobs one at a time, off the main actor, then files and expands each one; results hop back here.
    private func run(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        processingCount += jobs.count
        let processor = processor
        for job in jobs {
            enqueue(folder: job.folder) {
                let result = await Result { try await processor.process(meeting: job.meeting, tracks: job.tracks, folder: job.folder, noteURL: job.note) }
                await self.finished(result, folder: job.folder)
                if case .success = result { await self.expand(folder: job.folder, id: job.meeting.id) }
            }
        }
    }

    /// Runs the after-meeting step again for an already processed meeting (the meeting window's Retry).
    func runAfterMeeting(folder: URL) {
        enqueue(folder: folder) {
            do { await self.expand(folder: folder, id: try Meeting.load(from: folder).id) } catch {
                await self.report("Couldn't read \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Re-expand from the meeting window: streams into `liveExpansion` like the first expansion. Throws in plain
    /// English; the note is left as it was on failure.
    func reExpand(folder: URL, id: UUID) async throws {
        let after = afterMeeting
        busyFolders[folder.standardizedFileURL.path, default: 0] += 1
        defer { showExpansion(nil, for: id); endBusy(folder); revision += 1 }
        try await after.reExpand(folder: folder) { blocks in await self.showExpansion(blocks, for: id) }
    }

    private func enqueue(folder: URL, _ work: @escaping @Sendable () async -> Void) {
        busyFolders[folder.standardizedFileURL.path, default: 0] += 1
        let previous = pipeline
        pipeline = Task.detached {
            await previous?.value
            await work()
            await self.release(folder)
        }
    }

    private func release(_ folder: URL) { endBusy(folder) }

    private func endBusy(_ folder: URL) {
        let key = folder.standardizedFileURL.path
        busyFolders[key] = (busyFolders[key] ?? 1) > 1 ? (busyFolders[key] ?? 1) - 1 : nil
    }

    /// True while this meeting is being recorded, processed, queued or expanded: it can't be moved to the Trash then.
    func isBusy(folder: URL?, id: UUID?) -> Bool {
        if let id, liveExpansion[id] != nil { return true }
        guard let folder else { return false }
        let key = folder.standardizedFileURL.path
        return busyFolders[key] != nil || session?.folder.standardizedFileURL.path == key
            || liveMeeting?.folder.standardizedFileURL.path == key || startingFolder?.standardizedFileURL.path == key
    }

    /// Title, tags, rename and Claude's expansion. A failure is saved in meeting.json for the meeting window.
    private nonisolated func expand(folder: URL, id: UUID) async {
        let after = await afterMeeting
        do {
            try await after.run(folder: folder) { blocks in await self.showExpansion(blocks, for: id) }
        } catch {
            await report(ErrorBrief.sentence("Couldn't finish the notes for \(folder.lastPathComponent)", error))
        }
        await showExpansion(nil, for: id)
        await bumpRevision()
    }

    private func bumpRevision() { revision += 1 }

    private func showExpansion(_ blocks: [NoteBlock]?, for id: UUID) {
        liveExpansion[id] = blocks
    }

    private func finished(_ result: Result<URL, Error>, folder: URL) {
        processingCount -= 1
        revision += 1
        if case .failure(let error) = result {
            report("Processing \(folder.lastPathComponent) failed (will retry next launch): \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        lastError = message  // the latest problem only
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

enum Route: Equatable {
    case home
    case meeting(URL)
}

/// The Slides switch for the call being recorded, and how many slides it has saved.
struct CallSlides: Equatable {
    var on: Bool
    var count: Int
}

#if DEBUG
extension AppModel {
    /// Debug builds only: shows `folder` as the call being recorded, with its Slides switch, so the bottom bar can be
    /// looked at. Nothing records.
    func debugShowLiveCall(folder: URL, slides: Int) {
        liveMeeting = LiveMeeting(folder: folder, appName: "zoom.us")
        self.slides = CallSlides(on: slides > 0, count: slides)
    }

    /// Debug builds only: the Allow panel as a call would show it. Its buttons do nothing.
    func debugShowAllowPanel() {
        panel.show(app: "Google Chrome", title: "Meet - Coffee Roaster shoot", onAllow: {}, onAllowSlides: {}, onIgnore: {}, onAlwaysIgnore: {})
    }
}
#endif

struct LiveMeeting: Equatable {
    let folder: URL
    let appName: String
}
