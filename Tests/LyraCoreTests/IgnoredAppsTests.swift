import XCTest
@testable import LyraCore

final class IgnoredAppsTests: XCTestCase {
    let suite = "lyra.tests.ignoredApps"
    let whatsApp = MicUser(pid: 10, bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp")

    override func setUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    override func tearDown() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    func testIgnoredAppPersistsAcrossInstances() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        IgnoredApps(defaults: defaults).add(IgnoredApp(user: whatsApp))

        let reloaded = IgnoredApps(defaults: defaults)
        XCTAssertTrue(reloaded.contains(whatsApp))
        XCTAssertEqual(reloaded.all().map(\.name), ["WhatsApp"])

        reloaded.remove(IgnoredApp(user: whatsApp))
        XCTAssertFalse(IgnoredApps(defaults: defaults).contains(whatsApp))
    }

    func testAppWithoutBundleIDIgnoredByName() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let helper = MicUser(pid: 11, bundleID: "", appName: "voicenote")
        let ignored = IgnoredApps(defaults: defaults)
        ignored.add(IgnoredApp(user: helper))
        XCTAssertEqual(IgnoredApp(user: helper).key, "name:voicenote")
        XCTAssertTrue(ignored.contains(MicUser(pid: 99, bundleID: "", appName: "voicenote")))
        XCTAssertFalse(ignored.contains(MicUser(pid: 99, bundleID: "", appName: "other")))
    }

    func testAddingTwiceKeepsOneEntry() throws {
        let ignored = IgnoredApps(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        ignored.add(IgnoredApp(user: whatsApp))
        ignored.add(IgnoredApp(user: whatsApp))
        XCTAssertEqual(ignored.all().count, 1)
    }
}
