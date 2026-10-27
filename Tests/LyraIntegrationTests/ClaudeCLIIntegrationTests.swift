import XCTest
import LyraCore

final class ClaudeCLIIntegrationTests: XCTestCase {
    func testRealClaudeAnswersOk() async throws {
        try requireIntegration()
        let reply: String
        do {
            reply = try await ClaudeCLI().complete(system: "Be brief.", prompt: "Reply with the word ok")
        } catch {
            return XCTFail(error.localizedDescription)
        }
        print("Claude replied: \(reply)")
        XCTAssertTrue(reply.lowercased().contains("ok"), "unexpected reply: \(reply)")
    }
}
