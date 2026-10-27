import XCTest
@testable import LyraCore

final class ClaudeCLITests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fakeExecutable(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func delta(_ text: String) -> String {
        "echo '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}}'"
    }

    private let okResult = "echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"abc\"}'"

    private func collect(_ cli: ClaudeCLI) async throws -> [String] { try await Self.collectAll(cli) }

    private static func collectAll(_ cli: ClaudeCLI) async throws -> [String] {
        var out: [String] = []
        for try await piece in cli.stream(system: "s", prompt: "p", model: "sonnet") { out.append(piece) }
        return out
    }

    func testStripsSubscriptionBreakingKeys() {
        let env = ClaudeCLI.subscriptionEnvironment([
            "ANTHROPIC_API_KEY": "k", "ANTHROPIC_BASE_URL": "u", "ANTHROPIC_AUTH_TOKEN": "t",
            "PATH": "/usr/bin", "HOME": "/h",
        ])
        XCTAssertEqual(env, ["PATH": "/usr/bin", "HOME": "/h"])
    }

    func testYieldsTextDeltasInOrder() async throws {
        let exe = try fakeExecutable("""
        echo '{"type":"system","subtype":"init"}'
        \(delta("a"))
        echo 'not json at all'
        \(delta("b"))
        \(delta("c"))
        \(okResult)
        """)
        let pieces = try await collect(ClaudeCLI(executable: exe))
        XCTAssertEqual(pieces, ["a", "b", "c"])
    }

    func testCompleteJoinsDeltas() async throws {
        let exe = try fakeExecutable("\(delta("Hel"))\n\(delta("lo"))\n\(okResult)")
        let text = try await ClaudeCLI(executable: exe).complete(system: "s", prompt: "p")
        XCTAssertEqual(text, "Hello")
    }

    func testNonZeroExitThrowsPlainError() async throws {
        let exe = try fakeExecutable("echo 'login required' >&2\nexit 3")
        do {
            _ = try await collect(ClaudeCLI(executable: exe))
            XCTFail("expected failure")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .failed("login required"))
            XCTAssertEqual(error.errorDescription, "Claude couldn't answer: login required")
        }
    }

    func testErrorResultThrowsItsText() async throws {
        let exe = try fakeExecutable("""
        echo '{"type":"result","subtype":"success","is_error":true,"result":"usage limit reached"}'
        exit 1
        """)
        do {
            _ = try await collect(ClaudeCLI(executable: exe))
            XCTFail("expected failure")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .failed("usage limit reached"))
        }
    }

    func testMissingExecutableThrowsNotInstalled() async throws {
        let cli = ClaudeCLI(executable: dir.appendingPathComponent("nope"))
        do {
            _ = try await collect(cli)
            XCTFail("expected failure")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .notInstalled)
            XCTAssertEqual(error.errorDescription, "Claude Code isn't installed on this Mac.")
        }
    }

    func testPromptGoesThroughStdin() async throws {
        let captured = dir.appendingPathComponent("stdin.txt")
        let exe = try fakeExecutable("cat > '\(captured.path)'\n\(okResult)")
        _ = try await collect(ClaudeCLI(executable: exe))
        XCTAssertEqual(try String(contentsOf: captured, encoding: .utf8), "p")
    }

    func testPassesFlagsAndStrippedEnvironment() async throws {
        let captured = dir.appendingPathComponent("args.txt")
        let exe = try fakeExecutable("""
        echo "$@" > '\(captured.path)'
        echo "apikey=${ANTHROPIC_API_KEY:+present} keep=$KEEP" >> '\(captured.path)'
        \(okResult)
        """)
        let cli = ClaudeCLI(executable: exe, environment: ["ANTHROPIC_API_KEY": "x", "KEEP": "yes"])
        _ = try await collect(cli)
        let lines = try String(contentsOf: captured, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "-p --model sonnet --system-prompt s --tools  --setting-sources  --strict-mcp-config --no-session-persistence --output-format stream-json --verbose --include-partial-messages")
        XCTAssertEqual(lines[1], "apikey= keep=yes")
    }

    func testTimeoutTerminatesProcessAndThrowsTimedOut() async throws {
        let exe = try fakeExecutable("exec sleep 30")
        let cli = ClaudeCLI(executable: exe, timeout: .milliseconds(300))
        let started = ContinuousClock.now
        do {
            _ = try await collect(cli)
            XCTFail("expected timeout")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertEqual(error.errorDescription, "Claude took too long to answer.")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }

    func testCancellingConsumerTerminatesProcess() async throws {
        let pidFile = dir.appendingPathComponent("pid.txt")
        let exe = try fakeExecutable("echo $$ > '\(pidFile.path)'\n\(delta("a"))\nexec sleep 30")
        let cli = ClaudeCLI(executable: exe)
        let task = Task { try await Self.collectAll(cli) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text))
        task.cancel()
        var alive = true
        let killDeadline = ContinuousClock.now + .seconds(5)
        while alive, ContinuousClock.now < killDeadline {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertFalse(alive, "process should be gone after cancelling the consumer")
    }
}
