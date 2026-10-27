import Foundation

/// Talks to Google: finishes sign-in, keeps the access token fresh, and reads the coming week of the primary calendar.
/// The network is injected so tests run without it.
public actor GoogleCalendarClient {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let store: GoogleAccountStore
    private let send: Send
    private let clock: @Sendable () -> Date

    public init(store: GoogleAccountStore,
                send: @escaping Send = { try await URLSession.shared.data(for: $0) },
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.send = send
        self.clock = clock
    }

    /// Trades the browser's code for tokens and saves them.
    public func finishSignIn(client: GoogleClient, code: String, pkce: PKCE, redirect: URL) async throws {
        let (data, status) = try await call(GoogleAuth.codeRequest(client: client, code: code, pkce: pkce, redirect: redirect))
        let tokens = try GoogleAuth.tokens(from: data, status: status, now: clock())
        try store.save(.init(client: client, tokens: tokens))
    }

    /// Events from `now` to a week ahead, including ones already under way. Throws `.signedOut` when not connected.
    public func upcomingEvents() async throws -> [CalendarEvent] {
        let now = clock()
        var account = try currentAccount()
        var (data, status) = try await call(eventsRequest(now: now, token: try await accessToken(&account, now: now)))
        if status == 401 {  // revoked early or clock skew: one fresh token, then give up
            account.tokens = account.tokens.map { GoogleTokens(accessToken: "", refreshToken: $0.refreshToken, expiresAt: .distantPast) }
            (data, status) = try await call(eventsRequest(now: now, token: try await accessToken(&account, now: now)))
        }
        if status == 403, ["accessNotConfigured", "SERVICE_DISABLED"].contains(where: String(decoding: data, as: UTF8.self).contains) {
            throw GoogleCalendarError.apiDisabled
        }
        guard status == 200 else { throw status == 401 ? GoogleCalendarError.signedOut : GoogleCalendarError.badResponse(status) }
        return try GoogleEvents.parse(data)
    }

    private func currentAccount() throws -> GoogleAccountStore.Account {
        guard let account = try store.load(), account.tokens != nil else { throw GoogleCalendarError.signedOut }
        return account
    }

    /// The saved access token, or a refreshed one (saved) when it has under a minute left.
    private func accessToken(_ account: inout GoogleAccountStore.Account, now: Date) async throws -> String {
        guard let tokens = account.tokens else { throw GoogleCalendarError.signedOut }
        if tokens.expiresAt > now.addingTimeInterval(60) { return tokens.accessToken }
        let (data, status) = try await call(GoogleAuth.refreshRequest(client: account.client, refreshToken: tokens.refreshToken))
        let fresh = try GoogleAuth.tokens(from: data, status: status, now: now, keepingRefresh: tokens.refreshToken)
        account.tokens = fresh
        try store.save(account)
        return fresh.accessToken
    }

    private func eventsRequest(now: Date, token: String) -> URLRequest {
        let stamp = ISO8601DateFormatter()
        var parts = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        parts.queryItems = [
            .init(name: "timeMin", value: stamp.string(from: now)),
            .init(name: "timeMax", value: stamp.string(from: now.addingTimeInterval(Double(UpcomingMeetings.daysAhead) * 86_400))),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "250"),
        ]
        // `+` in a UTC offset would read as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func call(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await send(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
