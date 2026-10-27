import AppKit
import LyraCore
import UniformTypeIdentifiers

/// The home page's "Coming up": Aidan's Google calendar for the coming week, and connecting to it. One for the app,
/// so going home and back doesn't re-fetch. Last good list stays up when Google can't be reached.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    @Published private(set) var days: [UpcomingMeetings.Day] = []
    @Published private(set) var connected: Bool
    @Published private(set) var signingIn = false
    /// One plain-English line when something went wrong.
    @Published private(set) var problem: String?

    private let store = GoogleAccountStore(fileURL: GoogleAccountStore.defaultURL)
    private let google: GoogleCalendarClient
    private var events: [CalendarEvent] = []
    private var fetchedAt: Date?
    private var fetching = false
    private var listener: LoopbackListener?
    private var offline = false

    private init() {
        google = GoogleCalendarClient(store: store)
        connected = ((try? store.load()) ?? nil)?.tokens != nil
        #if DEBUG
        loadDebugEvents()
        #endif
    }

    /// Re-groups (so finished meetings drop off) and fetches again if the list is older than `maxAge` seconds.
    func refresh(maxAge: TimeInterval = 60) {
        days = UpcomingMeetings.days(events, now: Date())
        guard connected, !signingIn, !fetching, !offline else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < maxAge { return }
        fetching = true
        Task {
            defer { fetching = false }
            do {
                events = try await google.upcomingEvents()
                fetchedAt = Date()
                problem = nil
                days = UpcomingMeetings.days(events, now: Date())
            } catch GoogleCalendarError.signedOut {
                connected = false
                problem = GoogleCalendarError.signedOut.localizedDescription
            } catch {
                problem = ErrorBrief.sentence("Couldn't read Google Calendar", error)
            }
        }
    }

    /// Opens the call and arms the one automatic recording: when the meeting app takes the mic.
    func join(_ event: CalendarEvent, app: AppModel) {
        guard let url = event.joinURL else { return }
        app.pendingJoin = PendingJoin(title: event.title.isEmpty ? "Meeting" : event.title, until: event.end)
        NSWorkspace.shared.open(url)
    }

    /// Google sign-in in the default browser. The first time, Aidan picks the client JSON he downloaded.
    func connect() {
        guard !signingIn else { return }
        guard let client = savedClient() ?? pickClientFile() else { return }
        problem = nil
        signingIn = true
        Task {
            defer { signingIn = false; listener?.stop(); listener = nil }
            do {
                let listener = try LoopbackListener()
                self.listener = listener
                let redirect = try await listener.start()
                let (pkce, state) = (PKCE.make(), PKCE.randomToken())
                NSWorkspace.shared.open(GoogleAuth.authURL(client: client, redirect: redirect, pkce: pkce, state: state))
                let code = try GoogleAuth.code(fromCallback: try await listener.callbackTarget(), state: state)
                try await google.finishSignIn(client: client, code: code, pkce: pkce, redirect: redirect)
                connected = true
                fetchedAt = nil
                NSApp.activate()
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
            refresh()
        }
    }

    func cancelSignIn() { listener?.stop() }

    private func savedClient() -> GoogleClient? { ((try? store.load()) ?? nil)?.client }

    private func pickClientFile() -> GoogleClient? {
        let panel = NSOpenPanel()
        panel.message = "Choose the client_secret….json file you downloaded from Google Cloud Console."
        panel.prompt = "Use This File"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let client = try GoogleClient.parse(clientJSON: try Data(contentsOf: url))
            try store.save(.init(client: client))
            return client
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    #if DEBUG
    /// `LYRA_DEBUG_CALENDAR`: a saved `events.list` answer to show instead of Google, for screenshots.
    private func loadDebugEvents() {
        guard let path = ProcessInfo.processInfo.environment["LYRA_DEBUG_CALENDAR"] else { return }
        events = (try? GoogleEvents.parse(Data(contentsOf: URL(fileURLWithPath: path)))) ?? []
        connected = true
        offline = true
    }
    #endif
}
