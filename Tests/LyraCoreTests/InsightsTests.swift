import XCTest
@testable import LyraCore

private final class FakeClaude: ClaudeRunning, @unchecked Sendable {
    let reply: String
    var prompts: [String] = []
    init(_ reply: String) { self.reply = reply }
    func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        let reply = reply
        return AsyncThrowingStream { $0.yield(reply); $0.finish() }
    }
}

final class InsightsTests: XCTestCase {
    private func input(series: [String: [String]] = [:], known: [String] = [], clients: [String] = [],
                       transcript: [TranscriptLine] = []) -> InsightsInput {
        InsightsInput(windowTitle: "Google Meet", transcript: transcript, existingSeries: series,
                      knownTags: known, clients: clients)
    }

    func testParsesFencedJSON() throws {
        let reply = """
        Here you go:
        ```json
        {"title": "Pricing review", "tags": ["pricing"], "clients": [], "series": null, "summary": "Reviewed pricing."}
        ```
        """
        let result = try InsightsService.parse(reply, input: input())
        XCTAssertEqual(result, MeetingInsights(title: "Pricing review", tags: ["pricing"], clients: [], series: nil,
                                               summary: "Reviewed pricing."))
    }

    func testFallsBackToWindowTitleWhenTitleUnusable() throws {
        for title in ["", "  ab ", String(repeating: "x", count: 81)] {
            let json = #"{"title": "\#(title)", "tags": [], "clients": [], "series": null, "summary": ""}"#
            XCTAssertEqual(try InsightsService.parse(json, input: input()).title, "Google Meet")
        }
    }

    func testDropsUnknownClientsAndUsesInputSpelling() throws {
        let json = #"{"title": "Catch up", "tags": [], "clients": ["northwind coffee roasters", "Nobody Ltd"], "series": null, "summary": ""}"#
        let result = try InsightsService.parse(json, input: input(clients: ["Northwind Coffee Roasters", "Lantern Nightclub"]))
        XCTAssertEqual(result.clients, ["Northwind Coffee Roasters"])
    }

    func testNormalisesTags() throws {
        let json = #"{"title": "Catch up", "tags": ["Content Strategy", "meeting", "content_strategy", "AI!!", "Reels", "a", "b", "c", "d", "e"], "clients": [], "series": null, "summary": ""}"#
        let result = try InsightsService.parse(json, input: input())
        XCTAssertEqual(result.tags, ["content-strategy", "ai", "reels", "a", "b", "c"])
    }

    func testPrefersKnownTagSpelling() throws {
        let json = #"{"title": "Catch up", "tags": ["Short Form"], "clients": [], "series": null, "summary": ""}"#
        XCTAssertEqual(try InsightsService.parse(json, input: input(known: ["short-form"])).tags, ["short-form"])
    }

    func testSuggestsExistingSeriesNameVerbatim() async throws {
        let claude = FakeClaude(#"{"title": "Strategy", "tags": [], "clients": [], "series": " elm park startup series ", "summary": "Strategy workshop."}"#)
        let result = try await InsightsService.run(
            input(series: ["Elm Park Startup Series": ["Workshop 1"]]), claude: claude)
        XCTAssertEqual(result.series, "Elm Park Startup Series")
    }

    func testNewNoneAndEmptySeries() throws {
        func series(_ value: String) throws -> String? {
            try InsightsService.parse(#"{"title": "Strategy", "tags": [], "clients": [], "series": \#(value), "summary": ""}"#,
                                      input: input()).series
        }
        XCTAssertEqual(try series(#""Brand Sprint""#), "Brand Sprint")
        XCTAssertNil(try series(#""None""#))
        XCTAssertNil(try series(#""""#))
        XCTAssertNil(try series("null"))
    }

    func testSummaryCutAtWordBoundaryWithoutEllipsis() throws {
        let long = Array(repeating: "alpha", count: 40).joined(separator: " ")
        let json = #"{"title": "Strategy", "tags": [], "clients": [], "series": null, "summary": "\#(long)"}"#
        let summary = try InsightsService.parse(json, input: input()).summary
        XCTAssertLessThanOrEqual(summary.count, 140)
        XCTAssertTrue(summary.hasSuffix("alpha"))
        XCTAssertFalse(summary.hasSuffix("…"))
    }

    func testParseThrowsPlainErrors() {
        XCTAssertThrowsError(try InsightsService.parse("sorry, no", input: input())) {
            XCTAssertEqual($0 as? InsightsError, .noJSON)
        }
        XCTAssertThrowsError(try InsightsService.parse(#"{"title": "Hello there"}"#, input: input())) {
            XCTAssertEqual($0 as? InsightsError, .missingKeys(["tags", "summary"]))
        }
    }

    func testPromptKeepsOpeningAndEndOfLongTranscript() {
        let lines = (0..<2000).map {
            TranscriptLine(speakerLabel: "Speaker 1", track: .meeting, start: Double($0), end: Double($0) + 1, text: "line number \($0) with some filler words")
        }
        let prompt = Prompts.insightsUser(input: input(transcript: lines))
        XCTAssertTrue(prompt.contains("line number 0 "))
        XCTAssertTrue(prompt.contains("line number 1999 "))
        XCTAssertTrue(prompt.contains("[… trimmed …]"))
        XCTAssertFalse(prompt.contains("line number 1000 "))
    }

    func testClientsListsOnlyVisibleFolders() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clients = vault.appendingPathComponent("Clients")
        defer { try? FileManager.default.removeItem(at: vault) }
        for name in ["Zed", "Lantern Nightclub", ".hidden"] {
            try FileManager.default.createDirectory(at: clients.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "x".write(to: clients.appendingPathComponent("Index.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(InsightsService.clients(inVault: vault), ["Lantern Nightclub", "Zed"])
        XCTAssertEqual(InsightsService.clients(inVault: vault.appendingPathComponent("nope")), [])
    }
}
