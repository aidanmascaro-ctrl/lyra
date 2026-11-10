import AppKit
import CoreGraphics
import LyraAudio
import LyraCore
import LyraSpeech

/// Owns the whole flow: detect → prompt → record → process → note. All state lives on the main actor;
/// the detector is only touched here. Transcription runs detached, off the main actor.
///
/// Split by area so parallel work rarely edits the same file: detection in `AppModel+Detection.swift`, recording
/// in `AppModel+Recording.swift`, the background queue in `AppModel+Processing.swift`. Swift extensions in other
/// files can't see `private` members, so this state is module-visible: only the AppModel files may change it —
/// views read it and call AppModel's methods.
@MainActor
final class AppModel: ObservableObject {
    @Published var recordingSince: Date?
    /// When the running recording was paused; nil while it records.
    @Published var pausedSince: Date?
    /// Paused time before the current pause, left out of the elapsed time.
    var pausedBefore: TimeInterval = 0
    /// The note Record was pressed in, while its recording starts.
    @Published var startingFolder: URL?
    @Published var state = RecordingState()
    @Published var processingCount = 0
    /// Goes up whenever processing or the after-meeting step finishes a meeting, so open windows re-read it.
    @Published var revision = 0
    /// The meeting being recorded now, for New note.
    @Published var liveMeeting: LiveMeeting?
    /// What Lyra's one window shows: home, or a meeting.
    @Published var route: Route = .home
    @Published var lastError: String?
    @Published var now = Date()
    /// Apps the user chose to never be prompted about; mirrors the saved list so the menu refreshes.
    @Published var ignoredList: [IgnoredApp] = []
    /// Claude's Expanded section as it streams in, by meeting id; gone once it is saved in the note.
    @Published var liveExpansion: [UUID: [NoteBlock]] = [:]
    /// The rough live transcript of the meeting being recorded; thrown away when it stops.
    @Published var liveLines: [LiveLine] = []
    /// Set when live transcription gives up mid-meeting; the recording carries on regardless.
    @Published var liveError: String?
    /// Join was pressed on a meeting about to start: for a short while, the next meeting app to take the mic records
    /// without asking. Shown on home with a way to call it off.
    @Published var pendingJoin: PendingJoin?
    /// Slides for the call being recorded: nil when nothing records or the recording has no call window.
    @Published var slides: CallSlides?

    let paths = MeetingPaths(recordingsRoot: AppModel.recordingsRoot, notesDir: AppModel.notesRoot)
    /// Notes are found by `lyra_id` anywhere under Meetings/; links are rewritten across the whole vault.
    let notes = NoteIndex(notesRoot: AppModel.notesRoot, vaultRoot: AppModel.notesRoot.deletingLastPathComponent())
    /// The sidebar's folders and whether it shows.
    lazy var sidebar = SidebarModel(store: .live(index: notes, recordingsRoot: paths.recordingsRoot))
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
    lazy var processor: MeetingProcessor = { [people] in
        MeetingProcessor(
            trackTranscriber: TrackTranscriber(diarizer: FluidDiarizer(), transcriber: FluidTranscriber()),
            loader: { try AudioLoader.load16kMono(url: $0) },
            convert: M4AConverter.convert,
            people: { people.all() },
            learn: { name, sample in try people.learn(name: name, sample: sample) })
    }()
    lazy var afterMeeting: AfterMeeting = { [notes, talkNamer] in
        let claude = ClaudeCLI()
        return AfterMeeting(index: notes, claude: claude, expander: Expander(claude: claude), vaultRoot: notes.vaultRoot,
                            talkNamer: talkNamer)
    }()
    /// Names "Speaker N" voices from the conversation: after each meeting, and from Suggest names on the Transcript tab.
    lazy var talkNamer: TalkNamer = { [people] in
        TalkNamer(claude: ClaudeCLI(), people: { people.all().map(\.name) })
    }()
    /// The tail of the background queue: processing and after-meeting work run one at a time, in order.
    var pipeline: Task<Void, Never>?
    /// Meeting folders with processing, expansion or re-expansion queued or running (count per folder path).
    var busyFolders: [String: Int] = [:]
    let micUsage = CoreAudioMicUsage()
    let ignoredApps = IgnoredApps(defaults: .standard)
    let detector: MeetingDetector
    let panel = AllowPanel()
    var session: MeetingSession?
    var prompted: MicUser?
    var poller: Task<Void, Never>?

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
}

enum Route: Equatable {
    case home
    case meeting(URL)
    /// A sidebar folder's page, by name.
    case folder(String)
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
        liveMeeting = LiveMeeting(folder: folder, appName: "zoom.us", title: "Coffee Roaster shoot")
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
    /// The meeting's title (the calendar event's, when joined from the calendar), so Home can match it to its
    /// "Coming up" row and show one card instead of two.
    let title: String
}
