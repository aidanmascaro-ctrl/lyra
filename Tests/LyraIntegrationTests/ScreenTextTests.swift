import AppKit
import CoreGraphics
import LyraAudio
import XCTest

final class ScreenTextTests: XCTestCase {
    /// Reads whatever Finder is showing. Skips without Screen Recording permission; never prompts for it.
    func testReadsTextFromFinderWindow() async throws {
        try requireIntegration()
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Screen Recording permission not granted")
        let finder = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" })
        let lines = await ScreenText.read(pid: finder.processIdentifier)
        print("ScreenText lines from Finder: \(lines.prefix(5))")
        XCTAssertTrue(lines.allSatisfy { $0.count >= 3 })
        XCTAssertEqual(lines.count, Set(lines).count, "lines are deduplicated")
    }
}
