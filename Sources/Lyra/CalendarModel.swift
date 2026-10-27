import AppKit
import LyraCore
import UniformTypeIdentifiers

/// The home page's "Coming up": the coming week from every connected Google and Microsoft account, and connecting
/// them. One for the app, so going home and back doesn't re-fetch. An account that can't be reached keeps its last
/// list; one that was signed out drops its meetings and asks to reconnect.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    @Published private(set) var days: [UpcomingMeetings.Day] = []
    @Published private(set) var accounts: [CalendarAccount] = []
    /// Settings read and, if anything is connected, fetched once: until then nothing says "no meetings".
    @Published private(set) var ready = false
    @Published private(set) var signingIn: CalendarProvider?
    /// By account id.
    @Published private(set) var problems: [String: CalendarProblem] = [:]
    /// One plain-English line about connecting.
    @Published var notice: String?
    /// The "paste your Microsoft app ID" alert.
    @Published var askingForMicrosoftID = false

    /// `LYRA_CALENDARS_FILE` points Lyra at a scratch calendar list, like `LYRA_PEOPLE_FILE` for voices.
    private let service = CalendarService(
        store: CalendarStore(fileURL: ProcessInfo.processInfo.environment["LYRA_CALENDARS_FILE"]
            .map { URL(fileURLWithPath: $0) } ?? CalendarStore.defaultURL),
        builtIn: CalendarModel.builtInApps())
    private var eventsByAccount: [String: [CalendarEvent]] = [:]
    private var fetchedAt: Date?
    private var fetching = false
    private var listener: LoopbackListener?
    private var offline = false

    var connected: Bool { !accounts.isEmpty }

    private init() {
        #if DEBUG
        if loadDebugEvents() { return }
        #endif
        Task {
            await reloadAccounts()
            ready = accounts.isEmpty
            refresh()
        }
    }

    /// Re-groups (so finished meetings drop off) and fetches again if the list is older than `maxAge` seconds.
    func refresh(maxAge: TimeInterval = 60) {
        regroup()
        guard connected, signingIn == nil, !fetching, !offline else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < maxAge { return }
        fetching = true
        Task {
            do {
                for result in try await service.fetchAll() {
                    let id = result.account.id
                    if let events = result.events { eventsByAccount[id] = events }
                    else if result.problem?.needsSignIn == true { eventsByAccount[id] = nil }
                    problems[id] = result.problem
                }
                fetchedAt = Date()
            } catch {
                notice = ErrorBrief.sentence("Couldn't read Lyra's calendar settings", error)
            }
            fetching = false
            ready = true
            regroup()
        }
    }

    /// Opens the call. On a meeting about to start or under way it also arms the one automatic recording: when the
    /// meeting app takes the mic. Further off, it only opens the link.
    func join(_ event: CalendarEvent, app: AppModel) {
        guard let url = event.joinURL else { return }
        if let join = PendingJoin(event: event, now: Date()) { app.pendingJoin = join }
        NSWorkspace.shared.open(url)
    }

    /// Signs in to one more account (or again to one that was signed out) with Lyra's built-in app details, so it's
    /// only a sign-in. A build without them asks for the app details instead.
    func connect(_ provider: CalendarProvider) {
        guard signingIn == nil else { return }
        Task {
            if let client = try? await service.client(for: provider) { return await signIn(provider, client: client) }
            changeAppDetails(provider)
        }
    }

    /// New app details (a wrong or replaced Google file, a different Microsoft app), then a fresh sign-in.
    func changeAppDetails(_ provider: CalendarProvider) {
        switch provider {
        case .microsoft: askingForMicrosoftID = true
        case .google:
            guard let client = pickGoogleFile() else { return }
            Task { await signIn(.google, client: client) }
        }
    }

    func useMicrosoftID(_ text: String) {
        do {
            let client = try OAuthClient.microsoft(applicationID: text)
            Task { await signIn(.microsoft, client: client) }
        } catch {
            notice = error.localizedDescription
        }
    }

    func remove(_ account: CalendarAccount) {
        Task {
            do { try await service.removeAccount(account.id) } catch { notice = error.localizedDescription }
            eventsByAccount[account.id] = nil
            problems[account.id] = nil
            await reloadAccounts()
            regroup()
        }
    }

    func cancelSignIn() { listener?.stop() }

    private func signIn(_ provider: CalendarProvider, client: OAuthClient) async {
        guard signingIn == nil else { return }
        signingIn = provider
        notice = nil
        let listener = LoopbackListener()
        self.listener = listener
        do {
            let port = try await listener.start()
            let redirect = URL(string: "http://\(provider.redirectHost):\(port)")!
            let (pkce, state) = (PKCE.make(), PKCE.randomToken())
            NSWorkspace.shared.open(OAuth.authURL(provider, client: client, redirect: redirect, pkce: pkce, state: state))
            let code = try OAuth.code(fromCallback: try await listener.callbackTarget(), state: state)
            let account = try await service.finishSignIn(provider, client: client, code: code, pkce: pkce, redirect: redirect)
            problems[account.id] = nil
            NSApp.activate()
        } catch is CancellationError {
        } catch {
            notice = error.localizedDescription
        }
        listener.stop()
        self.listener = nil
        signingIn = nil
        await reloadAccounts()
        fetchedAt = nil
        refresh()
    }

    /// `CalendarApps.json` in the app bundle; none (a build without it) means connecting asks for app details.
    private static func builtInApps() -> [String: OAuthClient] {
        guard let url = Bundle.main.url(forResource: "CalendarApps", withExtension: "json") else { return [:] }
        do { return try BuiltInApps.parse(Data(contentsOf: url)) } catch {
            NSLog("Lyra: couldn't read the built-in calendar app details: \(error)")
            return [:]
        }
    }

    private func reloadAccounts() async {
        do { accounts = try await service.settings().accounts } catch {
            notice = ErrorBrief.sentence("Couldn't read Lyra's calendar settings", error)
        }
    }

    private func regroup() {
        days = UpcomingMeetings.days(UpcomingMeetings.merged(accounts.map { eventsByAccount[$0.id] ?? [] }), now: Date())
    }

    private func pickGoogleFile() -> OAuthClient? {
        let panel = NSOpenPanel()
        panel.message = "Choose the client_secret….json file you downloaded from Google Cloud Console."
        panel.prompt = "Use This File"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try OAuthClient.google(clientJSON: try Data(contentsOf: url)) } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    #if DEBUG
    /// `LYRA_DEBUG_CALENDAR` (a saved Google `events.list` answer) and `LYRA_DEBUG_OUTLOOK` (a Graph `calendarView`
    /// answer): shown instead of the real calendars, for screenshots.
    private func loadDebugEvents() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let google = env["LYRA_DEBUG_CALENDAR"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let outlook = env["LYRA_DEBUG_OUTLOOK"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        guard google != nil || outlook != nil else { return false }
        let placeholder = OAuthTokens(accessToken: "", refreshToken: "", expiresAt: .distantFuture)
        let client = OAuthClient(clientID: "debug")
        if let google {
            let account = CalendarAccount(provider: .google, email: "aidan@example.com", client: client, tokens: placeholder)
            accounts.append(account)
            eventsByAccount[account.id] = (try? GoogleEvents.parse(google))?.map { $0.inAccount(account.id) }
        }
        if let outlook {
            let account = CalendarAccount(provider: .microsoft, email: "aidan@work.example", client: client, tokens: placeholder)
            accounts.append(account)
            eventsByAccount[account.id] = (try? MicrosoftEvents.parse(outlook, selfEmail: account.email).events)?.map { $0.inAccount(account.id) }
        }
        offline = true
        ready = true
        regroup()
        return true
    }
    #endif
}
