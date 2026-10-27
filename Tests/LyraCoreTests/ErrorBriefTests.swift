import XCTest
@testable import LyraCore

final class ErrorBriefTests: XCTestCase {
    func testExpiredLoginTextsMapToSignedOut() {
        for text in ["Failed to authenticate: OAuth session expired", "Not logged in", "please run /login", "oauth token revoked"] {
            XCTAssertEqual(ClaudeError.classify(text), .signedOut, text)
        }
        XCTAssertEqual(ClaudeError.classify("usage limit reached"), .failed("usage limit reached"))
    }

    func testSignedOutSaysHowToFixIt() {
        XCTAssertEqual(ClaudeError.signedOut.errorDescription,
                       "Claude needs you to sign in again. Open Terminal, run claude, then type /login.")
    }

    func testClaudeErrorsAreNotWrappedAgain() {
        let message = ErrorBrief.sentence("Couldn't finish the notes for X", ClaudeError.failed("usage limit"))
        XCTAssertEqual(message, "Claude couldn't answer: usage limit")
        XCTAssertEqual(ErrorBrief.sentence("Couldn't finish the notes for X", ClaudeError.signedOut), ClaudeError.signInMessage)
    }

    func testOtherErrorsGetTheirPrefixOnce() {
        struct Disk: LocalizedError { var errorDescription: String? { "disk full" } }
        XCTAssertEqual(ErrorBrief.sentence("Couldn't save", Disk()), "Couldn't save: disk full")
    }

    func testMenuLineIsShortSignInForExpiredLogin() {
        let long = "Claude couldn't finish the notes for 2026-10-27 1527 — In-person meeting: Claude couldn't answer: Failed to authenticate: OAuth session expired and could not be refreshed"
        XCTAssertEqual(ErrorBrief.menuLine(long), "Claude needs you to sign in again")
        XCTAssertEqual(ErrorBrief.menuLine(ClaudeError.signInMessage), "Claude needs you to sign in again")
    }

    func testMenuLineShowsOnlyTheLatestProblemWithoutNestedPrefixes() {
        let two = "Couldn't recover A: nope\nClaude couldn't finish the notes for B: Claude couldn't answer: usage limit"
        XCTAssertEqual(ErrorBrief.menuLine(two), "Claude couldn't answer: usage limit")
    }

    func testMenuLineTruncatesWithAnEllipsis() {
        let line = ErrorBrief.menuLine(String(repeating: "word ", count: 40))
        XCTAssertLessThanOrEqual(line.count, ErrorBrief.menuLimit)
        XCTAssertTrue(line.hasSuffix("…"))
    }
}
