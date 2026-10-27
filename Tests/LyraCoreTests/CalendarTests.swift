import XCTest
@testable import LyraCore

final class GoogleEventsTests: XCTestCase {
    let perth = TimeZone(identifier: "Australia/Perth")!

    func testParsesMeetingWithAttendeesAndZoomInDescription() throws {
        let json = """
        {"items": [{
          "id": "vic", "status": "confirmed", "summary": " Elm Park Workshop 2 ",
          "description": "<p>ZOOM LINK: https://us02web.zoom.us/j/87079973750?pwd=Gy1</p><p>Hub: https://app.notion.com/p/x</p>",
          "start": {"dateTime": "2026-11-01T17:00:00+08:00"}, "end": {"dateTime": "2026-11-01T18:30:00+08:00"},
          "attendees": [
            {"email": "tomas@example.org", "organizer": true, "responseStatus": "accepted"},
            {"email": "room@resource.calendar.google.com", "resource": true},
            {"email": "aidan@example.com", "self": true, "responseStatus": "accepted"}
          ]
        }]}
        """
        let event = try XCTUnwrap(GoogleEvents.parse(Data(json.utf8), timeZone: perth).first)
        XCTAssertEqual(event.title, "Elm Park Workshop 2")
        XCTAssertEqual(event.otherAttendees, 1)
        XCTAssertFalse(event.declined)
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.joinURL?.absoluteString, "https://us02web.zoom.us/j/87079973750?pwd=Gy1")
        XCTAssertEqual(event.start, ISO8601DateFormatter().date(from: "2026-11-01T09:00:00Z"))
        XCTAssertTrue(event.isMeeting)
    }

    func testPersonalEventIsNotAMeeting() throws {
        let json = """
        {"items": [{"id": "sq", "summary": "dentist", "start": {"dateTime": "2026-10-29T13:00:00+08:00"},
                    "end": {"dateTime": "2026-10-29T19:00:00+08:00"}, "conferenceData": {}}]}
        """
        let event = try XCTUnwrap(GoogleEvents.parse(Data(json.utf8)).first)
        XCTAssertNil(event.joinURL)
        XCTAssertFalse(event.isMeeting)
    }

    func testAllDayDeclinedAndCancelled() throws {
        let json = """
        {"items": [
          {"id": "hol", "summary": "Holiday", "start": {"date": "2026-10-28"}, "end": {"date": "2026-10-29"},
           "hangoutLink": "https://meet.google.com/abc-defg-hij"},
          {"id": "no", "summary": "Declined", "start": {"dateTime": "2026-10-28T09:00:00Z"}, "end": {"dateTime": "2026-10-28T10:00:00Z"},
           "attendees": [{"email": "a@b.c"}, {"email": "me@x", "self": true, "responseStatus": "declined"}]},
          {"id": "gone", "status": "cancelled", "start": {"dateTime": "2026-10-28T09:00:00Z"}, "end": {"dateTime": "2026-10-28T10:00:00Z"}}
        ]}
        """
        let events = try GoogleEvents.parse(Data(json.utf8), timeZone: perth)
        XCTAssertEqual(events.map(\.id), ["hol", "no"])
        XCTAssertTrue(events[0].isAllDay)
        XCTAssertEqual(events[0].joinURL?.host, "meet.google.com")
        XCTAssertFalse(events[0].isMeeting)
        XCTAssertTrue(events[1].declined)
        XCTAssertFalse(events[1].isMeeting)
    }

    func testEmptyAnswerHasNoEvents() throws {
        XCTAssertEqual(try GoogleEvents.parse(Data("{}".utf8)), [])
    }
}

final class JoinLinkTests: XCTestCase {
    func testConferenceVideoLinkWinsOverText() {
        let url = JoinLink.find(conferenceURIs: ["https://meet.google.com/aaa-bbbb-ccc"], hangoutLink: nil,
                                location: "https://zoom.us/j/1", description: nil)
        XCTAssertEqual(url?.host, "meet.google.com")
    }

    func testFindsTeamsInLocationAndIgnoresOtherLinks() {
        XCTAssertNil(JoinLink.find(conferenceURIs: [], hangoutLink: nil, location: "Cafe, 10 Main St",
                                   description: "Agenda: https://notion.so/page"))
        let teams = JoinLink.find(conferenceURIs: [], hangoutLink: nil,
                                  location: "Teams: https://teams.microsoft.com/l/meetup-join/19%3ameeting", description: nil)
        XCTAssertEqual(teams?.host, "teams.microsoft.com")
    }

    func testLookalikeHostIsNotACall() {
        XCTAssertFalse(JoinLink.isCall(URL(string: "https://notzoom.us/j/1")!))
        XCTAssertTrue(JoinLink.isCall(URL(string: "https://us02web.zoom.us/j/1")!))
        XCTAssertFalse(JoinLink.isCall(URL(string: "zoommtg://zoom.us/join")!))
    }
}

final class UpcomingMeetingsTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }
    let now = ISO8601DateFormatter().date(from: "2026-10-28T02:00:00Z")!  // Wed 28 Oct, 10:00 Perth

    func meeting(_ id: String, hoursFromNow start: Double, length: Double = 1, people: Int = 2) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: now.addingTimeInterval(start * 3600),
                      end: now.addingTimeInterval((start + length) * 3600), otherAttendees: people)
    }

    func testGroupsByDayKeepsUnderWayAndDropsFinishedPersonalAndFar() {
        let events = [
            meeting("tomorrow", hoursFromNow: 24),
            meeting("underway", hoursFromNow: -0.5),
            meeting("finished", hoursFromNow: -3),
            meeting("later today", hoursFromNow: 3),
            meeting("dentist", hoursFromNow: 4, people: 0),
            meeting("next month", hoursFromNow: 24 * 8),
        ]
        let days = UpcomingMeetings.days(events, now: now, calendar: calendar)
        XCTAssertEqual(days.map { $0.events.map(\.id) }, [["underway", "later today"], ["tomorrow"]])
        XCTAssertEqual(UpcomingMeetings.label(for: days[0].date, now: now, calendar: calendar), "Today")
        XCTAssertEqual(UpcomingMeetings.label(for: days[1].date, now: now, calendar: calendar), "Tomorrow")
        XCTAssertTrue(days[0].events[0].isUnderWay(at: now))
    }

    func testLaterDaysAreNamed() {
        let day = calendar.startOfDay(for: now.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(UpcomingMeetings.label(for: day, now: now, calendar: calendar, locale: Locale(identifier: "en_AU")), "Sunday 1 Nov")
    }

    func testPendingJoinClaimsOnlyBeforeItsEnd() {
        let join = PendingJoin(title: "Elm Park", until: now)
        XCTAssertEqual(join.claim(now: now.addingTimeInterval(-60)), "Elm Park")
        XCTAssertNil(join.claim(now: now))
    }
}

final class GoogleAuthTests: XCTestCase {
    let client = GoogleClient(clientID: "id.apps.googleusercontent.com", clientSecret: "s+cret")

    func testPKCEMatchesRFC7636Example() {
        XCTAssertEqual(PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge,
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.make().verifier.count, 43)
    }

    func testReadsDesktopClientFileAndRejectsOthers() throws {
        let desktop = #"{"installed":{"client_id":"abc","client_secret":"xyz","redirect_uris":["http://localhost"]}}"#
        XCTAssertEqual(try GoogleClient.parse(clientJSON: Data(desktop.utf8)), GoogleClient(clientID: "abc", clientSecret: "xyz"))
        XCTAssertThrowsError(try GoogleClient.parse(clientJSON: Data(#"{"web":{"client_id":"a","client_secret":"b"}}"#.utf8))) {
            XCTAssertEqual($0 as? GoogleCalendarError, .webClient)
        }
        XCTAssertThrowsError(try GoogleClient.parse(clientJSON: Data("not json".utf8))) {
            XCTAssertEqual($0 as? GoogleCalendarError, .notAClientFile)
        }
    }

    func testAuthURLAsksForReadOnlyOfflineAccess() throws {
        let pkce = PKCE(verifier: "v")
        let url = GoogleAuth.authURL(client: client, redirect: URL(string: "http://127.0.0.1:5555")!, pkce: pkce, state: "st")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["scope"], GoogleAuth.scope)
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5555")
        XCTAssertEqual(items["state"], "st")
    }

    func testCallbackCodeChecksStateAndRefusal() throws {
        XCTAssertEqual(try GoogleAuth.code(fromCallback: "/?state=st&code=4/0Ab&scope=x", state: "st"), "4/0Ab")
        XCTAssertThrowsError(try GoogleAuth.code(fromCallback: "/?state=other&code=c", state: "st"))
        XCTAssertThrowsError(try GoogleAuth.code(fromCallback: "/?error=access_denied&state=st", state: "st")) {
            XCTAssertEqual($0 as? GoogleCalendarError, .signInRefused("access was not allowed"))
        }
    }

    func testTokenRequestsAreFormEncoded() throws {
        let request = GoogleAuth.refreshRequest(client: client, refreshToken: "1//r/t")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("client_secret=s%2Bcret"))
        XCTAssertTrue(body.contains("refresh_token=1%2F%2Fr%2Ft"))
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testTokenAnswers() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let first = try GoogleAuth.tokens(from: Data(#"{"access_token":"a","refresh_token":"r","expires_in":3599}"#.utf8), status: 200, now: now)
        XCTAssertEqual(first, GoogleTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3599)))
        let refreshed = try GoogleAuth.tokens(from: Data(#"{"access_token":"b","expires_in":10}"#.utf8), status: 200, now: now, keepingRefresh: "r")
        XCTAssertEqual(refreshed.refreshToken, "r")
        XCTAssertThrowsError(try GoogleAuth.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400, now: now)) {
            XCTAssertEqual($0 as? GoogleCalendarError, .signedOut)
        }
    }

    func testStoreIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GoogleAccountStore(fileURL: dir.appendingPathComponent("Lyra/google.json"))
        XCTAssertNil(try store.load())
        try store.save(.init(client: client))
        XCTAssertEqual(try store.load(), .init(client: client))
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

final class GoogleCalendarClientTests: XCTestCase {
    let client = GoogleClient(clientID: "id", clientSecret: "secret")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Answers by URL host: token endpoint vs calendar API; records every request.
    final class FakeGoogle: @unchecked Sendable {
        var requests: [URLRequest] = []
        var token = (200, #"{"access_token":"fresh","expires_in":3600}"#)
        var events: [(Int, String)] = [(200, #"{"items":[]}"#)]

        func send(_ request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            let (status, body) = request.url?.host == "oauth2.googleapis.com" ? token : (events.count > 1 ? events.removeFirst() : events[0])
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func makeClient(_ fake: FakeGoogle, tokens: GoogleTokens?) throws -> GoogleCalendarClient {
        let store = GoogleAccountStore(fileURL: dir.appendingPathComponent("google.json"))
        try store.save(.init(client: client, tokens: tokens))
        let now = now
        return GoogleCalendarClient(store: store, send: { fake.send($0) }, clock: { now })
    }

    func testNotSignedInThrowsSignedOut() async throws {
        let calendar = try makeClient(FakeGoogle(), tokens: nil)
        do { _ = try await calendar.upcomingEvents(); XCTFail("expected signedOut") } catch {
            XCTAssertEqual(error as? GoogleCalendarError, .signedOut)
        }
    }

    func testValidTokenReadsPrimaryCalendarForTheWeek() async throws {
        let fake = FakeGoogle()
        let calendar = try makeClient(fake, tokens: GoogleTokens(accessToken: "ok", refreshToken: "r", expiresAt: now.addingTimeInterval(600)))
        _ = try await calendar.upcomingEvents()
        XCTAssertEqual(fake.requests.count, 1)
        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ok")
        XCTAssertEqual(request.url?.path, "/calendar/v3/calendars/primary/events")
        XCTAssertTrue(request.url?.query?.contains("singleEvents=true") ?? false)
    }

    func testExpiredTokenIsRefreshedAndSaved() async throws {
        let fake = FakeGoogle()
        let calendar = try makeClient(fake, tokens: GoogleTokens(accessToken: "old", refreshToken: "r", expiresAt: now))
        _ = try await calendar.upcomingEvents()
        XCTAssertEqual(fake.requests.map { $0.url?.host }, ["oauth2.googleapis.com", "www.googleapis.com"])
        XCTAssertEqual(fake.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        let saved = try GoogleAccountStore(fileURL: dir.appendingPathComponent("google.json")).load()
        XCTAssertEqual(saved?.tokens?.accessToken, "fresh")
        XCTAssertEqual(saved?.tokens?.refreshToken, "r")
    }

    func testRejectedTokenRetriesOnceThenSignsOut() async throws {
        let fake = FakeGoogle()
        fake.events = [(401, "{}"), (401, "{}")]
        let calendar = try makeClient(fake, tokens: GoogleTokens(accessToken: "ok", refreshToken: "r", expiresAt: now.addingTimeInterval(600)))
        do { _ = try await calendar.upcomingEvents(); XCTFail("expected signedOut") } catch {
            XCTAssertEqual(error as? GoogleCalendarError, .signedOut)
        }
        XCTAssertEqual(fake.requests.count, 3)
    }

    func testDisabledAPIIsExplained() async throws {
        let fake = FakeGoogle()
        fake.events = [(403, #"{"error":{"errors":[{"reason":"accessNotConfigured"}]}}"#)]
        let calendar = try makeClient(fake, tokens: GoogleTokens(accessToken: "ok", refreshToken: "r", expiresAt: now.addingTimeInterval(600)))
        do { _ = try await calendar.upcomingEvents(); XCTFail("expected apiDisabled") } catch {
            XCTAssertEqual(error as? GoogleCalendarError, .apiDisabled)
        }
    }

    func testFinishSignInSavesTokens() async throws {
        let fake = FakeGoogle()
        fake.token = (200, #"{"access_token":"a","refresh_token":"r2","expires_in":3600}"#)
        let calendar = try makeClient(fake, tokens: nil)
        try await calendar.finishSignIn(client: client, code: "c", pkce: PKCE(verifier: "v"), redirect: URL(string: "http://127.0.0.1:1")!)
        let saved = try GoogleAccountStore(fileURL: dir.appendingPathComponent("google.json")).load()
        XCTAssertEqual(saved?.tokens?.refreshToken, "r2")
        XCTAssertTrue(String(decoding: fake.requests[0].httpBody ?? Data(), as: UTF8.self).contains("code_verifier=v"))
    }
}
