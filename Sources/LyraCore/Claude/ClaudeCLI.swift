import Foundation

public enum ClaudeError: Error, LocalizedError, Equatable {
    case notInstalled
    case failed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Claude Code isn't installed on this Mac."
        case .failed(let detail): "Claude couldn't answer: \(detail)"
        case .timedOut: "Claude took too long to answer."
        }
    }
}

public protocol ClaudeRunning: Sendable {
    /// Yields text deltas as they arrive; finishes after the result event.
    func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error>
}

extension ClaudeRunning {
    public func complete(system: String, prompt: String, model: String = ClaudeCLI.defaultModel) async throws -> String {
        var text = ""
        for try await piece in stream(system: system, prompt: prompt, model: model) { text += piece }
        return text
    }
}

/// Runs the Claude Code CLI on Aidan's subscription (never the paid API).
public struct ClaudeCLI: ClaudeRunning {
    public static let defaultModel = "sonnet"
    private static let strippedKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"]
    private static let stderrTailLength = 300

    private let executable: URL
    private let timeout: Duration
    private let environment: [String: String]

    public init(
        executable: URL = ClaudeCLI.defaultExecutable(),
        timeout: Duration = .seconds(300),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.timeout = timeout
        self.environment = environment
    }

    public static func defaultExecutable(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = env["CLAUDE_CLI_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
    }

    /// The CLI prefers an API key over the subscription login when one is set,
    /// so these would quietly bill the API.
    public static func subscriptionEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { !strippedKeys.contains($0.key) }
    }

    public func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let run = Run(
                executable: executable, timeout: timeout,
                environment: Self.subscriptionEnvironment(environment),
                arguments: Self.arguments(system: system, model: model),
                prompt: prompt)
            let task = Task { await run.execute(into: continuation) }
            continuation.onTermination = { _ in
                run.terminate()
                task.cancel()
            }
        }
    }

    private static func arguments(system: String, model: String) -> [String] {
        [
            "-p", "--model", model, "--system-prompt", system,
            "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        ]
    }

    /// One CLI invocation. A class so the process can be terminated from the
    /// timeout, the consumer going away, or the stream's termination handler.
    private final class Run: @unchecked Sendable {
        private let executable: URL
        private let timeout: Duration
        private let environment: [String: String]
        private let arguments: [String]
        private let prompt: String
        private let process = Process()
        private let lock = NSLock()
        private var stopped = false

        init(executable: URL, timeout: Duration, environment: [String: String], arguments: [String], prompt: String) {
            self.executable = executable
            self.timeout = timeout
            self.environment = environment
            self.arguments = arguments
            self.prompt = prompt
        }

        func terminate() {
            lock.lock()
            defer { lock.unlock() }
            stopped = true
            if process.isRunning { process.terminate() }
        }

        /// False if the run was already stopped, so a late launch never leaks a process.
        private func launch() throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if stopped { return false }
            try process.run()
            return true
        }

        func execute(into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                continuation.finish(throwing: ClaudeError.notInstalled)
                return
            }
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let exits = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { exits.continuation.yield($0.terminationStatus); exits.continuation.finish() }

            signal(SIGPIPE, SIG_IGN)
            do {
                if try !launch() { continuation.finish(); return }
            } catch {
                continuation.finish(throwing: ClaudeError.notInstalled)
                return
            }

            let prompt = self.prompt
            let writer = Task.detached {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            let stderrReader = Task.detached { (try? stderr.fileHandleForReading.readToEnd()) ?? Data() }

            let timer = Task {
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                terminate()
                continuation.finish(throwing: ClaudeError.timedOut)
            }
            defer { timer.cancel(); writer.cancel() }

            var resultError: String?
            var resultText: String?
            var yieldedDelta = false
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    switch ClaudeStreamLine.parse(line) {
                    case .delta(let text):
                        yieldedDelta = true
                        continuation.yield(text)
                    case .result(let isError, let text):
                        if isError { resultError = text } else { resultText = text }
                    case .ignored: break
                    }
                }
            } catch {
                terminate()
            }

            var status: Int32 = 0
            for await code in exits.stream { status = code }
            let errText = String(decoding: await stderrReader.value, as: UTF8.self)

            if let resultError {
                continuation.finish(throwing: ClaudeError.failed(resultError))
            } else if let resultText {
                // Insurance in case the CLI sends no partial deltas.
                if !yieldedDelta && !resultText.isEmpty { continuation.yield(resultText) }
                continuation.finish()
            } else {
                // No result event: the stream was cut short, whatever the exit status.
                let tail = String(errText.trimmingCharacters(in: .whitespacesAndNewlines).suffix(ClaudeCLI.stderrTailLength))
                let detail = tail.isEmpty ? (status == 0 ? "" : "exit code \(status)") : tail
                let message = "Claude stopped before finishing its answer."
                continuation.finish(throwing: ClaudeError.failed(detail.isEmpty ? message : "\(message) \(detail)"))
            }
        }
    }
}

/// One line of `--output-format stream-json` output.
enum ClaudeStreamLine: Equatable {
    case delta(String)
    case result(isError: Bool, text: String)
    case ignored

    static func parse(_ line: String) -> ClaudeStreamLine {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return .ignored }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .ignored }
            return .delta(text)
        case "result":
            return .result(isError: object["is_error"] as? Bool ?? false, text: object["result"] as? String ?? "")
        default:
            return .ignored
        }
    }
}
