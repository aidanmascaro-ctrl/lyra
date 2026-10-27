import XCTest
@testable import LyraCore

/// Answers the insights call with `insights` and the expansion call with `expansion`, told apart by system prompt.
private final class ScriptedClaude: ClaudeRunning, @unchecked Sendable {
    var insights: Result<String, Error>
    var expansion: [String]
    var expansionError: Error?
    private let lock = NSLock()
    private var calls: [(system: String, prompt: String)] = []

    init(insights: Result<String, Error>, expansion: [String], expansionError: Error? = nil) {
        self.insights = insights; self.expansion = expansion; self.expansionError = expansionError
    }

    var expansionPrompts: [String] { lock.withLock { calls.filter { $0.system != Prompts.insightsSystem }.map(\.prompt) } }

    func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { calls.append((system, prompt)) }
        let isInsights = system == Prompts.insightsSystem
        let (insights, expansion, failure) = (self.insights, self.expansion, self.expansionError)
        return AsyncThrowingStream { continuation in
            if isInsights {
                switch insights {
                case .success(let json): continuation.yield(json); continuation.finish()
                case .failure(let error): continuation.finish(throwing: error)
                }
            } else {
                for chunk in expansion { continuation.yield(chunk) }
                continuation.finish(throwing: failure)
            }
        }
    }
}

private actor Seen {
    var blocks: [[NoteBlock]] = []
    func add(_ b: [NoteBlock]) { blocks.append(b) }
}

final class AfterMeetingTests: XCTestCase {
    private var vault: URL!
    private var notesRoot: URL!
    private var folder: URL!
    private var reserved: URL!
    private var meeting: Meeting!

    private let insightsJSON = #"{"title": "Northwind pricing review", "tags": ["pricing", "Content Strategy"], "clients": ["northwind"], "series": "Northwind catch-ups", "summary": "Agreed new reel pricing."}"#
    private let expansionLines = ["@0\n- They agreed **$200** per unit\n", "@new Action items\n- Aidan sends the quote\n"]

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-after-\(UUID().uuidString)")
        vault = root.appendingPathComponent("vault")
        notesRoot = vault.appendingPathComponent("Meetings")
        folder = root.appendingPathComponent("rec/2027-01-15 1000 — Zoom Meeting")
        let fm = FileManager.default
        for dir in [notesRoot!, folder!, vault.appendingPathComponent("Clients/Northwind")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        reserved = notesRoot.appendingPathComponent("2027-01-15 1000 — Zoom Meeting.md")
        meeting = Meeting(title: "Zoom Meeting", appName: "zoom.us", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_800_000_600))
        meeting.notePath = reserved.path
        meeting.screenText = ["Northwind — pricing"]
        try MeetingProcessor.createSkeletonNote(for: meeting, recordingsFolder: folder, at: reserved)
        try meeting.save(in: folder)
        let lines = [TranscriptLine(speakerLabel: "Marco", track: .meeting, start: 0, end: 2, text: "Two hundred a unit works for us.")]
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent("transcript.json"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault.deletingLastPathComponent()) }

    private var index: NoteIndex { NoteIndex(notesRoot: notesRoot, vaultRoot: vault) }

    private func typeMyNotes(_ text: String) throws {
        let loaded = try index.load(meeting.id, hint: reserved)
        var doc = loaded.document
        doc.myNotes = text
        _ = try index.save(doc, over: loaded)
    }

    private func after(_ claude: ClaudeRunning, saveInterval: Duration = .seconds(1)) -> AfterMeeting {
        AfterMeeting(index: index, claude: claude, expander: Expander(claude: claude), vaultRoot: vault, saveInterval: saveInterval)
    }

    func testAfterMeetingWritesInsightsAndExpansion() async throws {
        try typeMyNotes("- pricing")
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        let seen = Seen()
        try await after(claude).run(folder: folder) { await seen.add($0) }

        let note = try index.load(meeting.id, hint: nil)
        XCTAssertEqual(note.url.lastPathComponent, "\(stamp(meeting.startedAt)) — Northwind pricing review.md")
        XCTAssertEqual(note.url.deletingLastPathComponent().standardizedFileURL, notesRoot.standardizedFileURL)  // no series yet
        XCTAssertFalse(FileManager.default.fileExists(atPath: reserved.path))
        let front = note.document.front
        XCTAssertEqual(front.title, "Northwind pricing review")
        XCTAssertEqual(front.tags, ["pricing", "content-strategy"])
        XCTAssertEqual(front.links, ["Northwind"])
        XCTAssertEqual(front.summary, "Agreed new reel pricing.")
        XCTAssertNil(front.series)  // a suggestion only, never an automatic join
        XCTAssertEqual(note.document.myNotes, "- pricing")

        let expanded = NoteMarkdown.parse(note.document.expanded)
        XCTAssertEqual(expanded.map(\.plainText), ["pricing", "They agreed $200 per unit", "Action items", "Aidan sends the quote"])
        XCTAssertEqual(expanded.map(\.byClaude), [false, true, true, true])

        let saved = try Meeting.load(from: folder)
        XCTAssertEqual(saved.expandedHashes, ExpandedMerge.hashes(of: expanded))
        XCTAssertEqual(saved.seriesSuggestion, "Northwind catch-ups")
        XCTAssertEqual(saved.notePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, note.url.resolvingSymlinksInPath())
        XCTAssertNil(saved.insightsError)
        XCTAssertNil(saved.expandError)
        let streamed = await seen.blocks
        XCTAssertEqual(streamed.last, expanded)
    }

    func testAfterMeetingClaudeFailureKeepsNoteAndRecordsError() async throws {
        try typeMyNotes("- pricing")
        let before = try String(contentsOf: reserved, encoding: .utf8)
        let failure = ClaudeError.failed("You've hit your usage limit.")
        let claude = ScriptedClaude(insights: .failure(failure), expansion: [], expansionError: failure)
        do {
            try await after(claude).run(folder: folder)
            XCTFail("expected throw")
        } catch {}

        XCTAssertEqual(try String(contentsOf: reserved, encoding: .utf8), before)  // still there, untouched
        let saved = try Meeting.load(from: folder)
        XCTAssertEqual(saved.insightsError, failure.localizedDescription)
        XCTAssertEqual(saved.expandError, failure.localizedDescription)
        XCTAssertNil(saved.expandedHashes)
        // The window title was used for the expansion.
        XCTAssertTrue(claude.expansionPrompts.first?.contains("Zoom Meeting") == true)
    }

    func testRetrySucceedsAndClearsErrors() async throws {
        let failure = ClaudeError.failed("offline")
        _ = try? await after(ScriptedClaude(insights: .failure(failure), expansion: [], expansionError: failure)).run(folder: folder)
        try await after(ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)).run(folder: folder)
        let saved = try Meeting.load(from: folder)
        XCTAssertNil(saved.insightsError)
        XCTAssertNil(saved.expandError)
        XCTAssertEqual(try index.load(meeting.id, hint: nil).document.front.title, "Northwind pricing review")
    }

    /// Streaming saves already wrote some grey; a failure must take it back out, not leave half an expansion.
    func testExpansionFailureMidStreamLeavesNoHalfWrittenGrey() async throws {
        try typeMyNotes("- pricing")
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines,
                                    expansionError: ClaudeError.failed("Claude stopped before finishing its answer."))
        let seen = Seen()
        do {
            try await after(claude, saveInterval: .zero).run(folder: folder) { await seen.add($0) }
            XCTFail("expected throw")
        } catch {}
        let streamed = await seen.blocks
        XCTAssertFalse(streamed.isEmpty)
        let note = try index.load(meeting.id, hint: nil)
        XCTAssertEqual(note.document.expanded, "")
        XCTAssertEqual(note.document.myNotes, "- pricing")
        XCTAssertEqual(note.document.front.title, "Northwind pricing review")  // insights stayed saved
        XCTAssertNotNil(try Meeting.load(from: folder).expandError)
    }

    func testExistingExpandedIsNeverReplaced() async throws {
        let loaded = try index.load(meeting.id, hint: reserved)
        var doc = loaded.document
        doc.expanded = "- my own write-up"
        _ = try index.save(doc, over: loaded)
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        try await after(claude).run(folder: folder)
        XCTAssertEqual(try index.load(meeting.id, hint: nil).document.expanded, "- my own write-up")
        XCTAssertTrue(claude.expansionPrompts.isEmpty)
    }

    /// A note Aidan moved into a series folder has joined it: it stays there, and earlier meetings in it are context.
    func testSeriesFolderNoteStaysAndGetsEarlierMeetings() async throws {
        let series = notesRoot.appendingPathComponent("Elm Park", isDirectory: true)
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        let earlier = Meeting(title: "Workshop 1: Basics", appName: "zoom.us", startedAt: meeting.startedAt.addingTimeInterval(-7 * 86_400))
        try MeetingProcessor.createSkeletonNote(for: earlier, recordingsFolder: folder, at: series.appendingPathComponent("Workshop 1.md"))
        let moved = series.appendingPathComponent("Zoom Meeting.md")
        try FileManager.default.moveItem(at: reserved, to: moved)

        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        try await after(claude).run(folder: folder)
        let note = try index.load(meeting.id, hint: nil)
        XCTAssertEqual(note.url.deletingLastPathComponent().standardizedFileURL, series.standardizedFileURL)
        XCTAssertTrue(claude.expansionPrompts.first?.contains("Workshop 1: Basics") == true)
    }

    func testUpdateRetriesWhenNoteChangesMidSave() throws {
        let loaded = try index.load(meeting.id, hint: reserved)
        var calls = 0
        let saved = try index.update(loaded) { doc in
            calls += 1
            if calls == 1 {  // Aidan types in Obsidian just as Lyra saves
                var typed = loaded.document
                typed.myNotes = "typed meanwhile"
                try? Data(typed.render().utf8).write(to: loaded.url)
            }
            doc.transcript = "filled"
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(saved.document.myNotes, "typed meanwhile")
        XCTAssertEqual(try index.load(meeting.id, hint: nil).document.transcript, "filled")
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f.string(from: date)
    }
}
