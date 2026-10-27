import XCTest
@testable import LyraCore

/// Answers the insights call with `insights` and the expansion call with `expansion`, told apart by system prompt.
private final class ScriptedClaude: ClaudeRunning, @unchecked Sendable {
    var insights: Result<String, Error>
    var expansion: [String]
    var expansionError: Error?
    /// Runs when the insights call is made: something else writing the meeting's files meanwhile.
    var duringInsights: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var calls: [(system: String, prompt: String)] = []

    init(insights: Result<String, Error>, expansion: [String], expansionError: Error? = nil) {
        self.insights = insights; self.expansion = expansion; self.expansionError = expansionError
    }

    var insightsCalls: Int { lock.withLock { calls.filter { $0.system == Prompts.insightsSystem }.count } }
    var expansionPrompts: [String] { lock.withLock { calls.filter { $0.system != Prompts.insightsSystem }.map(\.prompt) } }

    func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { calls.append((system, prompt)) }
        let isInsights = system == Prompts.insightsSystem
        if isInsights { duringInsights?() }
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

    // MARK: Fix round 1

    /// A rename from the meeting window lands while Claude is filing the meeting: its hash and names survive.
    func testRenameDuringRunSurvives() async throws {
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        let folder = self.folder!
        claude.duringInsights = {
            var renamed = try! Meeting.load(from: folder)
            renamed.transcriptSectionHash = "hash-after-rename"
            try! renamed.save(in: folder)
            let lines = [TranscriptLine(speakerLabel: "Elena", track: .meeting, start: 0, end: 2, text: "Two hundred a unit works for us.")]
            try! JSONEncoder().encode(lines).write(to: folder.appendingPathComponent("transcript.json"))
        }
        try await after(claude).run(folder: folder)
        let saved = try Meeting.load(from: folder)
        XCTAssertEqual(saved.transcriptSectionHash, "hash-after-rename")
        XCTAssertEqual(saved.afterMeetingDone, true)
        XCTAssertTrue(claude.expansionPrompts.first?.contains("Elena") == true)
    }

    func testFileFailureRecordsExpandError() async throws {
        try Data("not json".utf8).write(to: folder.appendingPathComponent("transcript.json"))
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        do {
            try await after(claude).run(folder: folder)
            XCTFail("expected throw")
        } catch {}
        let error = try XCTUnwrap(Meeting.load(from: folder).expandError)
        XCTAssertTrue(error.hasPrefix("Lyra couldn't read or save this meeting's files."), error)
        XCTAssertNil(try Meeting.load(from: folder).afterMeetingDone)
    }

    func testUnfinishedMarkerIsSavedWhileStreaming() async throws {
        let folder = self.folder!
        let marks = Seen()
        try await after(ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)).run(folder: folder) { _ in
            if (try? Meeting.load(from: folder).expandError) == AfterMeeting.unfinishedMessage { await marks.add([]) }
        }
        let streamed = await marks.blocks
        XCTAssertFalse(streamed.isEmpty)
        XCTAssertNil(try Meeting.load(from: folder).expandError)
    }

    /// Lyra quit mid-stream: Expanded holds part of its own grey (plus Aidan's point carried over). Retry replaces it.
    private func leaveUnfinishedStream(expanded: [NoteBlock], recorded: [NoteBlock]) throws {
        try typeMyNotes("- pricing")
        let loaded = try index.load(meeting.id, hint: reserved)
        var doc = loaded.document
        doc.expanded = NoteMarkdown.render(expanded)
        _ = try index.save(doc, over: loaded)
        try AfterMeeting.updateMeeting(in: folder) {
            $0.insightsDone = true
            $0.expandError = AfterMeeting.unfinishedMessage
            $0.expandedHashes = ExpandedMerge.hashes(of: recorded)
        }
    }

    private let mine = NoteBlock(kind: .bullet, runs: [.init(text: "pricing")])
    private let partial = NoteBlock(kind: .bullet, indent: 1, runs: [.init(text: "They agreed")], byClaude: true)

    func testRetryReplacesUntouchedUnfinishedStream() async throws {
        try leaveUnfinishedStream(expanded: [mine, partial], recorded: [partial])
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        try await after(claude).run(folder: folder)
        let expanded = NoteMarkdown.parse(try index.load(meeting.id, hint: nil).document.expanded)
        XCTAssertEqual(expanded.map(\.plainText), ["pricing", "They agreed $200 per unit", "Action items", "Aidan sends the quote"])
        XCTAssertEqual(claude.insightsCalls, 0)  // already done
        XCTAssertEqual(try Meeting.load(from: folder).afterMeetingDone, true)
    }

    func testRetryLeavesEditedGrey() async throws {
        var edited = partial
        edited.runs = [.init(text: "They agreed, said Aidan")]  // grey but not what Lyra wrote
        try leaveUnfinishedStream(expanded: [mine, edited], recorded: [partial])
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        try await after(claude).run(folder: folder)
        XCTAssertEqual(NoteMarkdown.parse(try index.load(meeting.id, hint: nil).document.expanded), [mine, edited])
        XCTAssertTrue(claude.expansionPrompts.isEmpty)
    }

    func testRetryLeavesWhiteTextAidanAdded() async throws {
        let added = NoteBlock(kind: .bullet, runs: [.init(text: "my own extra point")])
        try leaveUnfinishedStream(expanded: [mine, partial, added], recorded: [partial])
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        try await after(claude).run(folder: folder)
        XCTAssertEqual(NoteMarkdown.parse(try index.load(meeting.id, hint: nil).document.expanded), [mine, partial, added])
        XCTAssertTrue(claude.expansionPrompts.isEmpty)
    }

    func testInsightsRunOnlyOnceEvenWithEmptySummary() async throws {
        let empty = #"{"title": "Northwind pricing review", "tags": [], "clients": [], "series": null, "summary": ""}"#
        try await after(ScriptedClaude(insights: .success(empty), expansion: expansionLines)).run(folder: folder)
        let loaded = try index.load(meeting.id, hint: nil)
        var doc = loaded.document
        doc.front.title = "Aidan's title"
        _ = try index.save(doc, over: loaded)
        try AfterMeeting.updateMeeting(in: folder) { $0.expandError = "Claude couldn't answer: offline" }

        let again = ScriptedClaude(insights: .success(insightsJSON), expansion: expansionLines)
        try await after(again).run(folder: folder)
        XCTAssertEqual(again.insightsCalls, 0)
        XCTAssertEqual(try index.load(meeting.id, hint: nil).document.front.title, "Aidan's title")
    }

    func testPendingFoldersFindsOnlyUnfinishedPhase3Meetings() throws {
        let root = folder.deletingLastPathComponent()
        func make(_ name: String, transcript: Bool = true, _ change: (inout Meeting) -> Void) throws {
            let f = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            var m = Meeting(title: name, appName: "zoom.us", startedAt: Date())
            m.notePath = "/notes/\(name).md"
            change(&m)
            try m.save(in: f)
            if transcript { try Data("[]".utf8).write(to: f.appendingPathComponent("transcript.json")) }
        }
        try make("a-pending") { _ in }
        try make("b-done") { $0.afterMeetingDone = true }
        try make("c-phase2") { $0.notePath = nil }
        try make("d-unprocessed", transcript: false) { _ in }
        try make("e-failed") { $0.expandError = "Claude couldn't answer: offline" }
        try make("f-unfinished") { $0.expandError = AfterMeeting.unfinishedMessage }
        // setUp's folder: notePath set, processed, nothing recorded yet.
        XCTAssertEqual(AfterMeeting.pendingFolders(in: root).map(\.lastPathComponent), ["2027-01-15 1000 — Zoom Meeting", "a-pending"])
    }
    // MARK: Re-expand

    private func writeExpanded(_ text: String, hashes: [String]) throws {
        let loaded = try index.load(meeting.id, hint: nil)
        var doc = loaded.document
        doc.expanded = text
        _ = try index.save(doc, over: loaded)
        try AfterMeeting.updateMeeting(in: folder) { $0.expandedHashes = hashes; $0.afterMeetingDone = true; $0.insightsDone = true }
    }

    func testReExpandRewritesOnlyGreyAndFoldsInNewNotes() async throws {
        try typeMyNotes("- pricing\n- budget")
        let old = NoteMarkdown.parse("- pricing\n  - <span class=\"lyra\">old detail</span>")
        try writeExpanded(NoteMarkdown.render(old), hashes: ExpandedMerge.hashes(of: old))
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: ["@0\n- new detail\n"])
        let seen = Seen()
        try await after(claude).reExpand(folder: folder) { await seen.add($0) }

        let expanded = NoteMarkdown.parse(try index.load(meeting.id, hint: nil).document.expanded)
        XCTAssertEqual(expanded.map(\.plainText), ["pricing", "new detail", "budget"])
        XCTAssertEqual(expanded.map(\.byClaude), [false, true, false])
        XCTAssertTrue(try Meeting.load(from: folder).expandedHashes?.contains(ExpandedMerge.hashes(of: [expanded[1]])[0]) == true)
        XCTAssertEqual(try index.load(meeting.id, hint: nil).document.myNotes, "- pricing\n- budget")
        let streamed = await seen.blocks
        XCTAssertEqual(streamed.last, expanded)
    }

    func testReExpandFailureLeavesExpandedAsItWas() async throws {
        try typeMyNotes("- pricing")
        try writeExpanded("- pricing", hashes: [])
        let before = try String(contentsOf: index.find(meeting.id, hint: nil)!, encoding: .utf8)
        let claude = ScriptedClaude(insights: .success(insightsJSON), expansion: ["@0\n- half"], expansionError: ClaudeError.timedOut)
        do { try await after(claude).reExpand(folder: folder); XCTFail("expected throw") } catch {}
        XCTAssertEqual(try String(contentsOf: index.find(meeting.id, hint: nil)!, encoding: .utf8), before)
    }

    func testContextHasMyNotesAndTranscript() throws {
        try typeMyNotes("- pricing")
        let ctx = try AfterMeeting.context(for: try index.load(meeting.id, hint: nil), meetingFolder: folder, index: index)
        XCTAssertEqual(ctx.myNotes.map(\.plainText), ["pricing"])
        XCTAssertEqual(ctx.transcript.map(\.speakerLabel), ["Marco"])
        XCTAssertEqual(ctx.title, "Zoom Meeting")
    }
}
