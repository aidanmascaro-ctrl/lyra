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

final class MicrosoftEventsTests: XCTestCase {
    func testParsesTeamsMeetingInUTCAndCountsOthers() throws {
        let json = """
        {"value": [{
          "id": "AAMk1", "subject": "Weekly sync", "isAllDay": false, "isCancelled": false, "isOrganizer": false,
          "start": {"dateTime": "2026-10-28T01:00:00.0000000", "timeZone": "UTC"},
          "end": {"dateTime": "2026-10-28T01:30:00.0000000", "timeZone": "UTC"},
          "responseStatus": {"response": "accepted"},
          "organizer": {"emailAddress": {"name": "Jo", "address": "Jo@Client.com"}},
          "attendees": [
            {"type": "required", "emailAddress": {"address": "aidan@work.com"}},
            {"type": "optional", "emailAddress": {"address": "sam@client.com"}},
            {"type": "resource", "emailAddress": {"address": "room1@client.com"}}
          ],
          "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x"},
          "location": {"displayName": "Microsoft Teams Meeting"},
          "body": {"contentType": "text", "content": "Join on your computer"}
        }], "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendarView?$skip=100"}
        """
        let page = try MicrosoftEvents.parse(Data(json.utf8), selfEmail: "Aidan@work.com")
        let event = try XCTUnwrap(page.events.first)
        XCTAssertEqual(event.title, "Weekly sync")
        XCTAssertEqual(event.start, ISO8601DateFormatter().date(from: "2026-10-28T01:00:00Z"))
        XCTAssertEqual(event.otherAttendees, 2)  // Jo (organizer) and Sam; not Aidan, not the room
        XCTAssertEqual(event.joinURL?.host, "teams.microsoft.com")
        XCTAssertTrue(event.isMeeting)
        XCTAssertEqual(page.next?.query, "$skip=100")
    }

    func testOwnEventWithoutInviteesIsPersonalAndDeclinedOrCancelledDrop() throws {
        let json = """
        {"value": [
          {"id": "gym", "subject": "Gym", "isOrganizer": true,
           "start": {"dateTime": "2026-10-28T01:00:00.0000000", "timeZone": "UTC"}, "end": {"dateTime": "2026-10-28T02:00:00.0000000", "timeZone": "UTC"},
           "organizer": {"emailAddress": {"address": "aidan@outlook.com"}}, "attendees": []},
          {"id": "zoom", "subject": "Pitch", "responseStatus": {"response": "declined"},
           "start": {"dateTime": "2026-10-28T03:00:00.0000000", "timeZone": "UTC"}, "end": {"dateTime": "2026-10-28T04:00:00.0000000", "timeZone": "UTC"},
           "body": {"content": "Join Zoom Meeting https://us06web.zoom.us/j/555?pwd=abc Meeting ID: 555"}},
          {"id": "off", "subject": "Gone", "isCancelled": true,
           "start": {"dateTime": "2026-10-28T03:00:00.0000000", "timeZone": "UTC"}, "end": {"dateTime": "2026-10-28T04:00:00.0000000", "timeZone": "UTC"}}
        ]}
        """
        let events = try MicrosoftEvents.parse(Data(json.utf8), selfEmail: "someone-else@outlook.com").events
        XCTAssertEqual(events.map(\.id), ["gym", "zoom"])
        XCTAssertEqual(events[0].otherAttendees, 0)  // he organised it: the organizer isn't someone else
        XCTAssertFalse(events[0].isMeeting)
        XCTAssertEqual(events[1].joinURL?.absoluteString, "https://us06web.zoom.us/j/555?pwd=abc")
        XCTAssertTrue(events[1].declined)
        XCTAssertFalse(events[1].isMeeting)
    }

    func testRequestAsksForUTCPlainTextAndTheWeek() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let request = MicrosoftEvents.request(from: start, to: start.addingTimeInterval(7 * 86_400), token: "t")
        XCTAssertEqual(request.url?.path, "/v1.0/me/calendarView")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Prefer")?.contains(#"outlook.timezone="UTC""#) ?? false)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "startDateTime" }?.value, "2027-01-15T08:00:00Z")
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
        XCTAssertFalse(JoinLink.isCall(URL(string: "http://zoom.us/j/1")!), "only secure links count as calls")
    }
}

final class UpcomingMeetingsTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }
    let now = ISO8601DateFormatter().date(from: "2026-10-28T02:00:00Z")!  // Wed 28 Oct, 10:00 Perth
    let link = URL(string: "https://zoom.us/j/1")!

    func meeting(_ id: String, hoursFromNow start: Double, length: Double = 1, people: Int = 2, link: URL? = nil) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: now.addingTimeInterval(start * 3600),
                      end: now.addingTimeInterval((start + length) * 3600), otherAttendees: people, joinURL: link)
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

    func testSameMeetingInTwoCalendarsShowsOnceWithItsLink() {
        let google = meeting("Pitch", hoursFromNow: 2).inAccount("google:a")
        let outlook = meeting("Pitch", hoursFromNow: 2, link: link).inAccount("microsoft:b")
        let other = meeting("Other", hoursFromNow: 2).inAccount("microsoft:b")
        let merged = UpcomingMeetings.merged([[google], [outlook, other]])
        XCTAssertEqual(merged.map(\.id), ["microsoft:b|Pitch", "microsoft:b|Other"])
    }

    func testJoinArmsOnlyNearTheStartAndOnlyBriefly() throws {
        XCTAssertNil(PendingJoin(event: meeting("Thursday", hoursFromNow: 48, link: link), now: now), "days away: just opens the link")
        XCTAssertNil(PendingJoin(event: meeting("No link", hoursFromNow: 0.1), now: now))
        XCTAssertNil(PendingJoin(event: meeting("Over", hoursFromNow: -2, link: link), now: now))

        let zoom = ["us.zoom.xos"]
        let soon = try XCTUnwrap(PendingJoin(event: meeting("Elm Park", hoursFromNow: 0.2, link: link), now: now))
        XCTAssertEqual(soon.claim(now: now.addingTimeInterval(60), bundleIDs: zoom), "Elm Park")
        XCTAssertNil(soon.claim(now: now.addingTimeInterval(PendingJoin.window), bundleIDs: zoom), "15 minutes after Join it no longer fires")

        let endingSoon = try XCTUnwrap(PendingJoin(event: meeting("Wrap", hoursFromNow: -0.9, link: link), now: now))
        XCTAssertNil(endingSoon.claim(now: now.addingTimeInterval(7 * 60), bundleIDs: zoom), "never past the meeting's end")
    }

    func testOnlyTheCallsOwnAppOrABrowserClaimsTheJoin() throws {
        let soon = try XCTUnwrap(PendingJoin(event: meeting("Elm Park", hoursFromNow: 0.1, link: link), now: now))
        let later = now.addingTimeInterval(60)
        XCTAssertNil(soon.claim(now: later, bundleIDs: ["com.apple.VoiceMemos", ""]), "another app gets the Allow panel")
        XCTAssertNil(soon.claim(now: later, bundleIDs: ["com.microsoft.teams2"]), "Teams isn't where a Zoom call runs")
        XCTAssertEqual(soon.claim(now: later, bundleIDs: ["com.google.Chrome.helper", ""]), "Elm Park", "Zoom in the browser")
        XCTAssertEqual(soon.claim(now: later, bundleIDs: ["", "us.zoom.xos"]), "Elm Park", "the owning app counts")

        let teams = try XCTUnwrap(PendingJoin(event: meeting("Client", hoursFromNow: 0.1,
                                                             link: URL(string: "https://teams.microsoft.com/l/meetup-join/x")!), now: now))
        XCTAssertEqual(teams.claim(now: later, bundleIDs: ["com.microsoft.teams2"]), "Client")
        XCTAssertNil(teams.claim(now: later, bundleIDs: ["us.zoom.xos"]))
    }
}

final class OAuthTests: XCTestCase {
    let google = OAuthClient(clientID: "id.apps.googleusercontent.com", clientSecret: "s+cret")
    let microsoft = OAuthClient(clientID: "11111111-2222-3333-4444-555555555555")

    func testPKCEMatchesRFC7636Example() {
        XCTAssertEqual(PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge,
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.make().verifier.count, 43)
    }

    func testReadsGoogleDesktopClientFileAndRejectsOthers() throws {
        let desktop = #"{"installed":{"client_id":"abc","client_secret":"xyz","redirect_uris":["http://localhost"]}}"#
        XCTAssertEqual(try OAuthClient.google(clientJSON: Data(desktop.utf8)), OAuthClient(clientID: "abc", clientSecret: "xyz"))
        XCTAssertThrowsError(try OAuthClient.google(clientJSON: Data(#"{"web":{"client_id":"a","client_secret":"b"}}"#.utf8))) {
            XCTAssertEqual($0 as? CalendarError, .webClient)
        }
        XCTAssertThrowsError(try OAuthClient.google(clientJSON: Data("not json".utf8))) {
            XCTAssertEqual($0 as? CalendarError, .notAClientFile)
        }
    }

    func testMicrosoftApplicationIDIsAGUID() throws {
        XCTAssertEqual(try OAuthClient.microsoft(applicationID: "  1A2B3C4D-1111-2222-3333-444455556666\n").clientID,
                       "1a2b3c4d-1111-2222-3333-444455556666")
        XCTAssertThrowsError(try OAuthClient.microsoft(applicationID: "Lyra")) { XCTAssertEqual($0 as? CalendarError, .notAnApplicationID) }
    }

    func testAuthURLsAskForReadOnlyCalendarAccess() throws {
        func items(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let pkce = PKCE(verifier: "v")
        let g = items(OAuth.authURL(.google, client: google, redirect: URL(string: "http://127.0.0.1:5555")!, pkce: pkce, state: "st"))
        XCTAssertTrue(g["scope"]?.hasSuffix("calendar.readonly") ?? false)
        XCTAssertEqual(g["access_type"], "offline")
        XCTAssertEqual(g["code_challenge"], pkce.challenge)
        XCTAssertEqual(g["state"], "st")
        let msURL = OAuth.authURL(.microsoft, client: microsoft, redirect: URL(string: "http://localhost:5555")!, pkce: pkce, state: "st")
        XCTAssertEqual(msURL.host, "login.microsoftonline.com")
        let m = items(msURL)
        XCTAssertTrue(m["scope"]?.contains("offline_access") ?? false)
        XCTAssertTrue(m["scope"]?.contains("Calendars.Read") ?? false)
        XCTAssertEqual(m["prompt"], "select_account")
        XCTAssertEqual(m["redirect_uri"], "http://localhost:5555")
    }

    func testCallbackCodeChecksStateAndRefusals() throws {
        XCTAssertEqual(try OAuth.code(fromCallback: "/?state=st&code=4/0Ab&scope=x", state: "st"), "4/0Ab")
        XCTAssertThrowsError(try OAuth.code(fromCallback: "/?state=other&code=c", state: "st"))
        XCTAssertThrowsError(try OAuth.code(fromCallback: "/?error=access_denied&state=st", state: "st")) {
            XCTAssertEqual($0 as? CalendarError, .signInRefused("access was not allowed"))
        }
        let admin = "/?error=access_denied&error_description=AADSTS90094%3A+The+grant+requires+admin+permission.&state=st"
        XCTAssertThrowsError(try OAuth.code(fromCallback: admin, state: "st")) { XCTAssertEqual($0 as? CalendarError, .needsAdmin) }
    }

    func testTokenRequestsSendASecretOnlyForGoogle() throws {
        let g = String(decoding: try XCTUnwrap(OAuth.refreshRequest(.google, client: google, refreshToken: "1//r/t").httpBody), as: UTF8.self)
        XCTAssertTrue(g.contains("client_secret=s%2Bcret"))
        XCTAssertTrue(g.contains("refresh_token=1%2F%2Fr%2Ft"))
        XCTAssertFalse(g.contains("scope="))
        let m = String(decoding: try XCTUnwrap(OAuth.refreshRequest(.microsoft, client: microsoft, refreshToken: "r").httpBody), as: UTF8.self)
        XCTAssertFalse(m.contains("client_secret"))
        XCTAssertTrue(m.contains("scope=openid%20profile"))
    }

    func testTokenAnswers() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let first = try OAuth.tokens(from: Data(#"{"access_token":"a","refresh_token":"r","expires_in":3599}"#.utf8), status: 200, now: now)
        XCTAssertEqual(first, OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3599)))
        let refreshed = try OAuth.tokens(from: Data(#"{"access_token":"b","expires_in":10}"#.utf8), status: 200, now: now, keepingRefresh: "r")
        XCTAssertEqual(refreshed.refreshToken, "r")
        XCTAssertThrowsError(try OAuth.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400, now: now)) {
            XCTAssertEqual($0 as? CalendarError, .signedOut)
        }
        XCTAssertThrowsError(try OAuth.tokens(from: Data(#"{"error":"invalid_client"}"#.utf8), status: 401, now: now)) {
            XCTAssertEqual($0 as? CalendarError, .badClient)
        }
        let locked = #"{"error":"invalid_grant","error_description":"AADSTS65001: The user or administrator has not consented."}"#
        XCTAssertThrowsError(try OAuth.tokens(from: Data(locked.utf8), status: 400, now: now)) {
            XCTAssertEqual($0 as? CalendarError, .needsAdmin, "a work tenant needing approval isn't 'signed out'")
        }
    }

    func testBuiltInAppsFileReadsBothProviders() throws {
        let json = #"{"google":{"clientID":"g.apps.googleusercontent.com","clientSecret":"gs"},"microsoft":{"clientID":"11111111-2222-3333-4444-555555555555"}}"#
        let apps = try BuiltInApps.parse(Data(json.utf8))
        XCTAssertEqual(apps["google"], OAuthClient(clientID: "g.apps.googleusercontent.com", clientSecret: "gs"))
        XCTAssertEqual(apps["microsoft"], microsoft)
    }

    func testEmailComesFromTheIDToken() {
        func answer(_ claims: String) -> Data {
            let payload = PKCE.base64URL(Data(claims.utf8))
            return Data(#"{"access_token":"a","id_token":"eyJhbGciOiJub25lIn0.\#(payload).sig"}"#.utf8)
        }
        XCTAssertEqual(OAuth.email(fromTokenAnswer: answer(#"{"email":"aidan@example.com"}"#)), "aidan@example.com")
        XCTAssertEqual(OAuth.email(fromTokenAnswer: answer(#"{"preferred_username":"aidan@work.com"}"#)), "aidan@work.com")
        XCTAssertNil(OAuth.email(fromTokenAnswer: Data(#"{"access_token":"a"}"#.utf8)))
    }

    func testStoreIsOwnerOnlyAndAccountsReplaceBySameLogin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CalendarStore(fileURL: dir.appendingPathComponent("Lyra/calendars.json"), secrets: FakeSecrets())
        XCTAssertEqual(try store.load(), CalendarSettings())
        let settings = CalendarSettings().setting(google, for: .google)
            .adding(CalendarAccount(provider: .microsoft, email: "Aidan@work.com", client: microsoft))
            .adding(CalendarAccount(provider: .microsoft, email: "aidan@outlook.com", client: microsoft))
            .adding(CalendarAccount(provider: .microsoft, email: "aidan@work.com", client: microsoft))
        try store.save(settings)
        try store.save(settings)  // saving over an existing file
        let loaded = try store.load()
        XCTAssertEqual(loaded.client(for: .google), google)
        XCTAssertEqual(loaded.accounts.map(\.email), ["aidan@outlook.com", "aidan@work.com"])
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["calendars.json"], "no temporary files left behind")
    }
}

final class CalendarServiceTests: XCTestCase {
    let google = OAuthClient(clientID: "gid", clientSecret: "gs")
    let microsoft = OAuthClient(clientID: "11111111-2222-3333-4444-555555555555")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    let secrets = FakeSecrets()
    var store: CalendarStore { CalendarStore(fileURL: dir.appendingPathComponent("calendars.json"), secrets: secrets) }

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Answers by host; records every request. Calendar answers are queued per host (the last one repeats).
    final class FakeServers: @unchecked Sendable {
        var requests: [URLRequest] = []
        var token = (200, #"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#)
        var answers: [String: [(Int, String)]] = [
            "www.googleapis.com": [(200, #"{"items":[]}"#)],
            "graph.microsoft.com": [(200, #"{"value":[]}"#)],
        ]

        func send(_ request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            let host = request.url?.host ?? ""
            let (status, body): (Int, String)
            if host == "oauth2.googleapis.com" || host == "login.microsoftonline.com" {
                (status, body) = token
            } else {
                var queue = answers[host] ?? [(404, "{}")]
                (status, body) = queue.count > 1 ? queue.removeFirst() : queue[0]
                answers[host] = queue
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func service(_ fake: FakeServers, accounts: [CalendarAccount]) throws -> CalendarService {
        var settings = CalendarSettings().setting(google, for: .google).setting(microsoft, for: .microsoft)
        for account in accounts { settings = settings.adding(account) }
        try store.save(settings)
        let now = now
        return CalendarService(store: store, send: { fake.send($0) }, clock: { now })
    }

    func account(_ provider: CalendarProvider, _ email: String, expiresIn: TimeInterval = 600) -> CalendarAccount {
        let account = CalendarAccount(provider: provider, email: email, client: provider == .google ? google : microsoft)
        try? store.storeTokens(OAuthTokens(accessToken: "ok", refreshToken: "r", expiresAt: now.addingTimeInterval(expiresIn)), for: account.id)
        return account
    }

    func testReadsEveryAccountAndOneFailureDoesNotHideTheOthers() async throws {
        let fake = FakeServers()
        fake.answers["graph.microsoft.com"] = [(500, "{}")]
        fake.answers["www.googleapis.com"] = [(200, #"{"items":[{"id":"g1","summary":"Pitch","start":{"dateTime":"2027-01-15T09:00:00Z"},"end":{"dateTime":"2027-01-15T10:00:00Z"},"hangoutLink":"https://meet.google.com/x"}]}"#)]
        let calendars = try service(fake, accounts: [account(.google, "a@gmail.com"), account(.microsoft, "a@work.com")])
        let results = try await calendars.fetchAll()
        XCTAssertEqual(results.map(\.account.id), ["google:a@gmail.com", "microsoft:a@work.com"])
        XCTAssertEqual(results[0].events?.map(\.id), ["google:a@gmail.com|g1"])
        XCTAssertNil(results[1].events)
        XCTAssertEqual(results[1].problem?.needsSignIn, false)
        let graph = try XCTUnwrap(fake.requests.first { $0.url?.host == "graph.microsoft.com" })
        XCTAssertEqual(graph.value(forHTTPHeaderField: "Authorization"), "Bearer ok")
    }

    func testMicrosoftPagesAreFollowed() async throws {
        let fake = FakeServers()
        let event = #"{"id":"%@","subject":"S","start":{"dateTime":"2027-01-15T09:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2027-01-15T10:00:00.0000000","timeZone":"UTC"}}"#
        fake.answers["graph.microsoft.com"] = [
            (200, #"{"value":[\#(String(format: event, "m1"))],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=2"}"#),
            (200, #"{"value":[\#(String(format: event, "m2"))]}"#),
        ]
        let calendars = try service(fake, accounts: [account(.microsoft, "a@outlook.com")])
        let results = try await calendars.fetchAll()
        XCTAssertEqual(results[0].events?.map(\.id), ["microsoft:a@outlook.com|m1", "microsoft:a@outlook.com|m2"])
        XCTAssertEqual(fake.requests.last?.url?.query, "$skiptoken=2")
    }

    func testExpiredTokenIsRefreshedAndTheRotatedOneSaved() async throws {
        let fake = FakeServers()
        let calendars = try service(fake, accounts: [account(.microsoft, "a@work.com", expiresIn: 0)])
        _ = try await calendars.fetchAll()
        XCTAssertEqual(fake.requests.map { $0.url?.host }, ["login.microsoftonline.com", "graph.microsoft.com"])
        XCTAssertEqual(fake.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        let saved = try store.tokens(for: "microsoft:a@work.com")
        XCTAssertEqual(saved?.accessToken, "fresh")
        XCTAssertEqual(saved?.refreshToken, "rotated")
    }

    func testRefusedTokenRetriesOnceThenAsksToSignIn() async throws {
        let fake = FakeServers()
        fake.answers["www.googleapis.com"] = [(401, "{}")]
        let calendars = try service(fake, accounts: [account(.google, "a@gmail.com")])
        let result = try await calendars.fetchAll()[0]
        XCTAssertEqual(result.problem, CalendarProblem(CalendarError.signedOut))
        XCTAssertTrue(result.problem?.needsSignIn ?? false)
        XCTAssertEqual(fake.requests.count, 3)  // read, refresh, read
    }

    func testDisabledGoogleAPIIsExplained() async throws {
        let fake = FakeServers()
        fake.answers["www.googleapis.com"] = [(403, #"{"error":{"errors":[{"reason":"accessNotConfigured"}]}}"#)]
        let calendars = try service(fake, accounts: [account(.google, "a@gmail.com")])
        let result = try await calendars.fetchAll()[0]
        XCTAssertEqual(result.problem, CalendarProblem(CalendarError.apiDisabled))
    }

    func testBuiltInAppDetailsAreUsedUnlessOthersWereChosen() async throws {
        let builtIn = OAuthClient(clientID: "built-in")
        let calendars = CalendarService(store: store, builtIn: ["microsoft": builtIn])
        let nothingSaved = try await calendars.client(for: .microsoft)
        XCTAssertEqual(nothingSaved, builtIn)
        let noGoogle = try await calendars.client(for: .google)
        XCTAssertNil(noGoogle)
        try store.save(CalendarSettings().setting(microsoft, for: .microsoft))
        let chosen = try await calendars.client(for: .microsoft)
        XCTAssertEqual(chosen, microsoft)
    }

    func testNewAppDetailsAreKeptOnlyWhenSignInWorksAndOldAccountsKeepTheirOwn() async throws {
        let fake = FakeServers()
        fake.token = (400, #"{"error":"invalid_client"}"#)
        let calendars = try service(fake, accounts: [account(.microsoft, "a@work.com")])
        let typo = OAuthClient(clientID: "99999999-2222-3333-4444-555555555555")
        do {
            _ = try await calendars.finishSignIn(.microsoft, client: typo, code: "c", pkce: PKCE(verifier: "v"), redirect: URL(string: "http://localhost:1")!)
            XCTFail("expected badClient")
        } catch { XCTAssertEqual(error as? CalendarError, .badClient) }
        XCTAssertEqual(try store.load().client(for: .microsoft), microsoft)

        fake.token = (200, #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#)
        let other = OAuthClient(clientID: "88888888-2222-3333-4444-555555555555")
        _ = try await calendars.finishSignIn(.microsoft, client: other, code: "c", pkce: PKCE(verifier: "v"), redirect: URL(string: "http://localhost:1")!)
        let saved = try store.load()
        XCTAssertEqual(saved.client(for: .microsoft), other)
        XCTAssertEqual(saved.accounts.first { $0.email == "a@work.com" }?.client, microsoft, "refreshes with the app that signed it in")
    }

    func testFinishSignInSavesTheAccountUnderItsEmail() async throws {
        let fake = FakeServers()
        let payload = PKCE.base64URL(Data(#"{"preferred_username":"aidan@work.com"}"#.utf8))
        fake.token = (200, #"{"access_token":"a","refresh_token":"r2","expires_in":3600,"id_token":"h.\#(payload).s"}"#)
        let calendars = try service(fake, accounts: [])
        let added = try await calendars.finishSignIn(.microsoft, client: microsoft, code: "c", pkce: PKCE(verifier: "v"),
                                                     redirect: URL(string: "http://localhost:1")!)
        XCTAssertEqual(added.id, "microsoft:aidan@work.com")
        XCTAssertEqual(try store.tokens(for: added.id)?.refreshToken, "r2")
        XCTAssertEqual(try store.load().accounts.first?.client, microsoft)
        let body = String(decoding: fake.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("code_verifier=v"))
        XCTAssertFalse(body.contains("client_secret"))
    }
}
