import Foundation

/// What one account gave: its events, or why not.
public struct AccountFetch: Sendable {
    public let account: CalendarAccount
    /// Nil when it couldn't be read.
    public let events: [CalendarEvent]?
    public let problem: CalendarProblem?
}

public struct CalendarProblem: Equatable, Sendable {
    public let message: String
    /// Signing in again (or new app details) is the way out; otherwise trying again later is.
    public let needsSignIn: Bool

    public init(_ error: Error) {
        if let known = error as? CalendarError {
            message = known.localizedDescription
            needsSignIn = [.signedOut, .needsAdmin, .badClient].contains(known)
        } else {
            message = ErrorBrief.sentence("Couldn't reach the calendar", error)
            needsSignIn = false
        }
    }
}

/// Talks to Google and Microsoft: finishes sign-ins, keeps each account's access token fresh, and reads the coming
/// week of each account's main calendar. Owns the settings file, so token saves never race. The network is
/// injected so tests run without it.
public actor CalendarService {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Microsoft pages of 100; a week never needs more than a few.
    static let maxPages = 5

    private let store: CalendarStore
    private let send: Send
    private let clock: @Sendable () -> Date

    public init(store: CalendarStore,
                send: @escaping Send = { try await URLSession.shared.data(for: $0) },
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.send = send
        self.clock = clock
    }

    public func settings() throws -> CalendarSettings { try store.load() }

    public func removeAccount(_ id: String) throws { try store.save(try store.load().removing(accountID: id)) }

    /// Trades the browser's code for tokens and saves the account (replacing an earlier sign-in to it). The app
    /// details become the ones for new sign-ins only now, so a mistyped ID never touches the other accounts.
    public func finishSignIn(_ provider: CalendarProvider, client: OAuthClient, code: String, pkce: PKCE, redirect: URL) async throws -> CalendarAccount {
        let (data, status) = try await call(OAuth.codeRequest(provider, client: client, code: code, pkce: pkce, redirect: redirect))
        let account = CalendarAccount(provider: provider, email: OAuth.email(fromTokenAnswer: data) ?? "", client: client,
                                      tokens: try OAuth.tokens(from: data, status: status, now: clock()))
        try store.save(try store.load().setting(client, for: provider).adding(account))
        return account
    }

    /// Every account, from now to a week ahead (meetings under way included). One account failing doesn't stop the others.
    public func fetchAll() async throws -> [AccountFetch] {
        let settings = try store.load()
        var results: [AccountFetch] = []
        for account in settings.accounts {
            do {
                let events = try await events(for: account, client: account.client)
                results.append(AccountFetch(account: account, events: events.map { $0.inAccount(account.id) }, problem: nil))
            } catch {
                results.append(AccountFetch(account: account, events: nil, problem: CalendarProblem(error)))
            }
        }
        return results
    }

    /// One read; on 401 (revoked early, clock skew) one fresh token and a second read, then give up.
    private func events(for account: CalendarAccount, client: OAuthClient) async throws -> [CalendarEvent] {
        let now = clock()
        let end = now.addingTimeInterval(Double(UpcomingMeetings.daysAhead) * 86_400)
        var token = try await accessToken(account, client: client, now: now, force: false)
        if let events = try await read(account, from: now, to: end, token: token) { return events }
        token = try await accessToken(account, client: client, now: now, force: true)
        if let events = try await read(account, from: now, to: end, token: token) { return events }
        throw CalendarError.signedOut
    }

    /// The events, or nil when the token was refused.
    private func read(_ account: CalendarAccount, from start: Date, to end: Date, token: String) async throws -> [CalendarEvent]? {
        switch account.provider {
        case .google:
            let (data, status) = try await call(GoogleEvents.request(from: start, to: end, token: token))
            try check(status, data)
            return status == 401 ? nil : try GoogleEvents.parse(data)
        case .microsoft:
            var request = MicrosoftEvents.request(from: start, to: end, token: token)
            var events: [CalendarEvent] = []
            for _ in 0..<Self.maxPages {
                let (data, status) = try await call(request)
                try check(status, data)
                if status == 401 { return nil }
                let page = try MicrosoftEvents.parse(data, selfEmail: account.email)
                events += page.events
                guard let next = page.next else { break }
                request = MicrosoftEvents.page(next, token: token)
            }
            return events
        }
    }

    private func check(_ status: Int, _ data: Data) throws {
        guard status != 200, status != 401 else { return }
        if status == 403, ["accessNotConfigured", "SERVICE_DISABLED"].contains(where: String(decoding: data, as: UTF8.self).contains) {
            throw CalendarError.apiDisabled
        }
        throw CalendarError.badResponse(status)
    }

    /// The saved access token, or a refreshed one (saved) when it has under a minute left or was refused.
    private func accessToken(_ account: CalendarAccount, client: OAuthClient, now: Date, force: Bool) async throws -> String {
        let current = try store.load().accounts.first { $0.id == account.id }?.tokens ?? account.tokens
        if !force, current.expiresAt > now.addingTimeInterval(60) { return current.accessToken }
        let (data, status) = try await call(OAuth.refreshRequest(account.provider, client: client, refreshToken: current.refreshToken))
        let fresh = try OAuth.tokens(from: data, status: status, now: now, keepingRefresh: current.refreshToken)
        try store.save(try store.load().updating(tokens: fresh, for: account.id))
        return fresh.accessToken
    }

    private func call(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await send(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
