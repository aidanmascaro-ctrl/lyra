import XCTest
@testable import LyraCore

/// A stand-in for the macOS Keychain that can be told to refuse, or to claim a write it didn't keep.
final class FakeSecrets: SecretStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var refusedWrites: Set<String> = []
    private var refusedReads: Set<String> = []
    private var refusedDeletes: Set<String> = []
    private var droppedWrites: Set<String> = []
    private(set) var writeCount = 0

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func refuseWrites(to key: String, _ refuse: Bool = true) { locked { if refuse { refusedWrites.insert(key) } else { refusedWrites.remove(key) } } }
    func refuseReads(of key: String) { locked { _ = refusedReads.insert(key) } }
    func refuseDeletes(of key: String) { locked { _ = refusedDeletes.insert(key) } }
    /// The write reports success but nothing is kept: only reading it back shows that.
    func dropWrites(to key: String) { locked { _ = droppedWrites.insert(key) } }
    func put(_ data: Data, for key: String) { locked { entries[key] = data } }
    func has(_ key: String) -> Bool { locked { entries[key] != nil } }

    func read(_ key: String) throws -> Data? {
        try locked {
            if refusedReads.contains(key) { throw Refused() }
            return entries[key]
        }
    }

    func write(_ data: Data, for key: String) throws {
        try locked {
            writeCount += 1
            if refusedWrites.contains(key) { throw Refused() }
            if !droppedWrites.contains(key) { entries[key] = data }
        }
    }

    func delete(_ key: String) throws {
        try locked {
            if refusedDeletes.contains(key) { throw Refused() }
            entries[key] = nil
        }
    }
}

final class CalendarTokenStorageTests: XCTestCase {
    let workID = "microsoft:a@work.example"
    let homeID = "google:a@home.example"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let secrets = FakeSecrets()
    var dir: URL!

    var store: CalendarStore { CalendarStore(fileURL: dir.appendingPathComponent("Lyra/calendars.json"), secrets: secrets) }
    var fileText: String { (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? "" }

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.fileURL.deletingLastPathComponent().path)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A `calendars.json` exactly as earlier versions of Lyra wrote it: every account's tokens in the file.
    func writeOldFile(workExpiry: TimeInterval = 600) throws {
        func account(_ provider: String, _ email: String, _ name: String, _ expiry: TimeInterval) -> String {
            let date = now.addingTimeInterval(expiry).timeIntervalSinceReferenceDate
            return #"{"provider":"\#(provider)","email":"\#(email)","client":{"clientID":"\#(provider)-id"},"tokens":{"accessToken":"\#(name)-access-plain","refreshToken":"\#(name)-refresh-plain","expiresAt":\#(date)}}"#
        }
        let json = #"{"clients":{"google":{"clientID":"google-id"}},"accounts":[\#(account("microsoft", "a@work.example", "work", workExpiry)),\#(account("google", "a@home.example", "home", 600))]}"#
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
    }

    func service(_ fake: CalendarServiceTests.FakeServers) -> CalendarService {
        let now = now
        return CalendarService(store: store, send: { fake.send($0) }, clock: { now })
    }

    func tokens(_ name: String, expiresIn: TimeInterval = 600) -> OAuthTokens {
        OAuthTokens(accessToken: "\(name)-access", refreshToken: "\(name)-refresh", expiresAt: now.addingTimeInterval(expiresIn))
    }

    // MARK: Moving existing accounts

    func testOldFileMovesToTheKeychainAndLeavesNoPlaintext() async throws {
        try writeOldFile()
        let fake = CalendarServiceTests.FakeServers()
        let calendars = service(fake)

        let waiting = try await calendars.migrateTokens()

        XCTAssertEqual(waiting, 0)
        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "work-refresh-plain")
        XCTAssertEqual(try store.tokens(for: homeID)?.accessToken, "home-access-plain")
        XCTAssertFalse(fileText.contains("plain"), "no token left in the file")
        XCTAssertFalse(fileText.contains("tokens"), "no token field left in the file")
        let settings = try store.load()
        XCTAssertEqual(settings.accounts.map(\.id), [workID, homeID], "accounts stay, so no sign-in is needed")
        XCTAssertEqual(settings.client(for: .google)?.clientID, "google-id")
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        // Reads the calendars with the moved token, without signing in or even refreshing.
        let results = try await calendars.fetchAll()
        XCTAssertEqual(results.map { $0.problem }, [nil, nil])
        XCTAssertFalse(fake.requests.contains { $0.url?.host == "login.microsoftonline.com" || $0.url?.host == "oauth2.googleapis.com" })
        let graph = try XCTUnwrap(fake.requests.first { $0.url?.host == "graph.microsoft.com" })
        XCTAssertEqual(graph.value(forHTTPHeaderField: "Authorization"), "Bearer work-access-plain")
    }

    func testMigrationOnlyHappensOnce() throws {
        try writeOldFile()
        XCTAssertEqual(try store.migrateLegacyTokens(), 0)
        let writes = secrets.writeCount
        let modified = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        let inode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.systemFileNumber] as? Int

        XCTAssertEqual(try store.migrateLegacyTokens(), 0)

        XCTAssertEqual(secrets.writeCount, writes, "nothing written to the Keychain again")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.systemFileNumber] as? Int, inode, "file not rewritten")
    }

    func testNothingToMoveWhenNeverConnected() throws {
        XCTAssertEqual(try store.migrateLegacyTokens(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(secrets.writeCount, 0)
    }

    func testRefusedWriteKeepsThatAccountsTokensAndMovesTheOther() async throws {
        try writeOldFile()
        secrets.refuseWrites(to: workID)
        let fake = CalendarServiceTests.FakeServers()
        let calendars = service(fake)

        let waiting = try await calendars.migrateTokens()

        XCTAssertEqual(waiting, 1)
        XCTAssertTrue(fileText.contains("work-refresh-plain"), "kept until the Keychain has it")
        XCTAssertFalse(fileText.contains("home-refresh-plain"))
        let results = try await calendars.fetchAll()
        XCTAssertEqual(results.map { $0.problem }, [nil, nil], "still reads the calendar in the meantime")

        secrets.refuseWrites(to: workID, false)
        let retried = try await calendars.migrateTokens()
        XCTAssertEqual(retried, 0)
        XCTAssertFalse(fileText.contains("plain"))
        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "work-refresh-plain")
    }

    func testWriteThatDoesNotReadBackKeepsTheOldTokens() throws {
        try writeOldFile()
        secrets.dropWrites(to: workID)

        XCTAssertEqual(try store.migrateLegacyTokens(), 1)

        XCTAssertTrue(fileText.contains("work-refresh-plain"))
        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "work-refresh-plain")
    }

    func testFileThatCannotBeRewrittenLosesNothingAndIsFinishedLater() throws {
        try writeOldFile()
        let folder = store.fileURL.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)

        XCTAssertThrowsError(try store.migrateLegacyTokens())

        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "work-refresh-plain")
        XCTAssertTrue(fileText.contains("work-refresh-plain"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        XCTAssertEqual(try store.migrateLegacyTokens(), 0)
        XCTAssertFalse(fileText.contains("plain"))
        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "work-refresh-plain")
    }

    func testNewerTokensInTheKeychainAreNotReplacedByAnOlderFileCopy() throws {
        try writeOldFile()
        try store.storeTokens(tokens("newer", expiresIn: 3600), for: workID)

        XCTAssertEqual(try store.migrateLegacyTokens(), 0)

        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "newer-refresh")
        XCTAssertFalse(fileText.contains("plain"))
    }

    func testKeychainCopyThatCannotBeCheckedIsLeftAloneAndTheMoveWaits() throws {
        try writeOldFile()
        secrets.put(try JSONEncoder().encode(tokens("newer", expiresIn: 3600)), for: workID)
        secrets.refuseReads(of: workID)
        let writes = secrets.writeCount

        XCTAssertEqual(try store.migrateLegacyTokens(), 1)

        XCTAssertEqual(secrets.writeCount, writes + 1, "only the other account was written")
        XCTAssertTrue(fileText.contains("work-refresh-plain"))
        XCTAssertFalse(fileText.contains("home-refresh-plain"))
    }

    func testAddingAnAccountKeepsTokensThatHaveNotMovedYet() async throws {
        try writeOldFile()
        secrets.refuseWrites(to: workID)
        let fake = CalendarServiceTests.FakeServers()
        fake.token = (200, #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#)
        let calendars = service(fake)
        _ = try await calendars.migrateTokens()

        _ = try await calendars.finishSignIn(.google, client: OAuthClient(clientID: "google-id"), code: "c", pkce: PKCE(verifier: "v"), redirect: URL(string: "http://127.0.0.1:1")!)

        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "work-refresh-plain")
    }

    // MARK: Refreshing

    func testRefreshedTokensGoToTheKeychainNotTheFile() async throws {
        try writeOldFile(workExpiry: 0)
        let fake = CalendarServiceTests.FakeServers()
        let calendars = service(fake)
        _ = try await calendars.migrateTokens()

        _ = try await calendars.fetchAll()

        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "rotated")
        XCTAssertFalse(fileText.contains("rotated"))
        XCTAssertFalse(fileText.contains("fresh"))
    }

    func testRefreshOfAnUnmovedAccountFinishesTheMoveWhenTheKeychainRecovers() async throws {
        try writeOldFile(workExpiry: 0)
        secrets.refuseWrites(to: workID)
        let fake = CalendarServiceTests.FakeServers()
        let calendars = service(fake)
        _ = try await calendars.migrateTokens()
        secrets.refuseWrites(to: workID, false)

        _ = try await calendars.fetchAll()

        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "rotated")
        XCTAssertFalse(fileText.contains("plain"))
        XCTAssertFalse(fileText.contains("rotated"))
    }

    func testRotatedTokenIsNotLostWhileTheKeychainStaysRefusedForAnUnmovedAccount() async throws {
        try writeOldFile(workExpiry: 0)
        secrets.refuseWrites(to: workID)
        let fake = CalendarServiceTests.FakeServers()
        let calendars = service(fake)
        _ = try await calendars.migrateTokens()

        let results = try await calendars.fetchAll()

        XCTAssertNil(results[0].problem)
        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "rotated", "only ever in the file it was already in")
    }

    func testRefreshFinishingAfterTheAccountWasRemovedLeavesNoTokensBehind() throws {
        try store.save(CalendarSettings())

        try store.updateTokens(tokens("late"), for: workID)

        XCTAssertFalse(secrets.has(workID))
    }

    func testMovedAccountNeverFallsBackToTheFile() async throws {
        try store.save(CalendarSettings().adding(account(.microsoft, "a@work.example")))
        try store.storeTokens(tokens("work", expiresIn: 0), for: workID)
        secrets.refuseWrites(to: workID)
        let fake = CalendarServiceTests.FakeServers()

        let results = try await service(fake).fetchAll()

        XCTAssertEqual(results[0].problem?.needsSignIn, false, "try again later, not sign in again")
        XCTAssertFalse(fileText.contains("rotated"))
    }

    // MARK: Failures reading

    func testKeychainRefusingAReadIsNotASignOut() async throws {
        try store.save(CalendarSettings().adding(account(.microsoft, "a@work.example")))
        try store.storeTokens(tokens("work"), for: workID)
        secrets.refuseReads(of: workID)
        let fake = CalendarServiceTests.FakeServers()

        let results = try await service(fake).fetchAll()

        XCTAssertNil(results[0].events)
        XCTAssertEqual(results[0].problem?.needsSignIn, false)
        XCTAssertTrue(fake.requests.isEmpty)
        XCTAssertTrue(secrets.has(workID), "tokens untouched")
    }

    func testMissingTokensAskToSignInAgain() async throws {
        try store.save(CalendarSettings().adding(account(.microsoft, "a@work.example")))
        let fake = CalendarServiceTests.FakeServers()

        let results = try await service(fake).fetchAll()

        XCTAssertEqual(results[0].problem, CalendarProblem(CalendarError.signedOut))
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testUnreadableKeychainEntryAsksToSignInAgain() async throws {
        try store.save(CalendarSettings().adding(account(.microsoft, "a@work.example")))
        secrets.put(Data("not tokens".utf8), for: workID)

        let results = try await service(CalendarServiceTests.FakeServers()).fetchAll()

        XCTAssertEqual(results[0].problem, CalendarProblem(CalendarError.signedOut))
    }

    // MARK: Signing in and removing

    func testSignInPutsTokensInTheKeychainOnly() async throws {
        let fake = CalendarServiceTests.FakeServers()
        fake.token = (200, #"{"access_token":"signed-in-access","refresh_token":"signed-in-refresh","expires_in":3600}"#)

        let added = try await service(fake).finishSignIn(.google, client: OAuthClient(clientID: "g"), code: "c", pkce: PKCE(verifier: "v"), redirect: URL(string: "http://127.0.0.1:1")!)

        XCTAssertEqual(try store.tokens(for: added.id)?.refreshToken, "signed-in-refresh")
        XCTAssertFalse(fileText.contains("signed-in"))
        XCTAssertEqual(try store.load().accounts.map(\.id), [added.id])
    }

    func testSignInThatCannotBeSavedFailsAndKeepsTheEarlierAccount() async throws {
        try writeOldFile()
        secrets.refuseWrites(to: workID)
        let fake = CalendarServiceTests.FakeServers()
        let payload = PKCE.base64URL(Data(#"{"preferred_username":"a@work.example"}"#.utf8))
        fake.token = (200, #"{"access_token":"a","refresh_token":"new","expires_in":3600,"id_token":"h.\#(payload).s"}"#)
        let calendars = service(fake)
        _ = try await calendars.migrateTokens()

        do {
            _ = try await calendars.finishSignIn(.microsoft, client: OAuthClient(clientID: "m"), code: "c", pkce: PKCE(verifier: "v"), redirect: URL(string: "http://localhost:1")!)
            XCTFail("expected the sign-in to fail")
        } catch {}

        XCTAssertEqual(try store.tokens(for: workID)?.refreshToken, "work-refresh-plain")
        XCTAssertFalse(fileText.contains("\"new\""))
    }

    func testRemovingAnAccountRemovesItsTokens() async throws {
        try writeOldFile()
        let calendars = service(CalendarServiceTests.FakeServers())
        _ = try await calendars.migrateTokens()

        try await calendars.removeAccount(workID)

        XCTAssertFalse(secrets.has(workID))
        XCTAssertTrue(secrets.has(homeID))
        XCTAssertEqual(try store.load().accounts.map(\.id), [homeID])
    }

    func testAccountStaysListedWhenItsTokensCannotBeRemoved() async throws {
        try writeOldFile()
        secrets.refuseDeletes(of: workID)
        let calendars = service(CalendarServiceTests.FakeServers())
        _ = try await calendars.migrateTokens()

        do {
            try await calendars.removeAccount(workID)
            XCTFail("expected the removal to fail")
        } catch {}

        XCTAssertEqual(try store.load().accounts.map(\.id), [workID, homeID], "not hidden while its tokens remain")
    }

    private func account(_ provider: CalendarProvider, _ email: String) -> CalendarAccount {
        CalendarAccount(provider: provider, email: email, client: OAuthClient(clientID: "\(provider.rawValue)-id"))
    }
}
