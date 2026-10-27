import XCTest
@testable import LyraCore

/// Plays back scripted chunks and remembers what it was asked.
private final class FakeClaude: ClaudeRunning, @unchecked Sendable {
    private let chunks: [String]
    private let lock = NSLock()
    private var prompts: [String] = []

    init(_ chunks: [String]) { self.chunks = chunks }

    var lastPrompt: String { lock.withLock { prompts.last ?? "" } }

    func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { prompts.append(prompt) }
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

final class ExpanderTests: XCTestCase {
    private func b(_ text: String, _ kind: BlockKind = .bullet, indent: Int = 0, grey: Bool = false) -> NoteBlock {
        NoteBlock(kind: kind, indent: indent, runs: [.init(text: text)], byClaude: grey)
    }

    private func line(_ who: String, _ start: Double, _ text: String) -> TranscriptLine {
        TranscriptLine(speakerLabel: who, track: .meeting, start: start, end: start + 1, text: text)
    }

    private func ctx(notes: [NoteBlock] = [], transcript: [TranscriptLine] = [], earlier: [EarlierMeeting] = []) -> MeetingContext {
        MeetingContext(title: "Northwind catch-up", myNotes: notes, transcript: transcript, earlier: earlier)
    }

    private func last(_ stream: AsyncThrowingStream<[NoteBlock], Error>) async throws -> ([NoteBlock], Int) {
        var latest: [NoteBlock] = []
        var count = 0
        for try await blocks in stream { latest = blocks; count += 1 }
        return (latest, count)
    }

    // MARK: Parser

    func testParserHandlesChunksSplitMidLine() {
        var parser = ExpansionParser(targets: [b("Intro"), b("Pricing")])
        XCTAssertEqual(parser.feed("@1\n- de"), [])
        XCTAssertEqual(parser.feed("tail\n@new Risks\n- one\n"), [
            .under(index: 1, b("detail", indent: 1, grey: true)),
            .section(b("Risks", .heading2, grey: true)),
            .bullet(b("one", grey: true)),
        ])
        XCTAssertEqual(parser.finish(), [])
    }

    func testParserFinishFlushesALastLineWithNoNewline() {
        var parser = ExpansionParser(targets: [b("Intro")])
        XCTAssertEqual(parser.feed("@0\n- **last**"), [])
        XCTAssertEqual(parser.finish(), [
            .under(index: 0, NoteBlock(kind: .bullet, indent: 1, runs: [.init(text: "last", bold: true)], byClaude: true)),
        ])
    }

    func testUnparseableLinesAreIgnored() {
        var parser = ExpansionParser(targets: [b("Intro"), b("Claude's", indent: 1, grey: true)])
        let junk = "Sure, here are the notes:\n- orphan before any target\n@x\n- lost\n@99\n- lost too\n"
            + "@1\n- under a grey block\n@new\n- no heading\nJust some prose.\n```\n"
        XCTAssertEqual(parser.feed(junk), [])
        XCTAssertEqual(parser.feed("@0\n- kept\n"), [.under(index: 0, b("kept", indent: 1, grey: true))])
        XCTAssertEqual(parser.finish(), [])
    }

    func testNewHeadingKeepsTrailingHashes() {
        var parser = ExpansionParser(targets: [])
        XCTAssertEqual(parser.feed("@new ## Learning F#  \n"), [.section(b("Learning F#", .heading2, grey: true))])
    }

    func testHeadersTolerateSmallFormatWobble() {
        let targets = [b("A"), b("B"), b("C"), b("D")]
        for header in ["@3", "@3:", "@3.", "@ 3", "@#3", "  @3 "] {
            var parser = ExpansionParser(targets: targets)
            XCTAssertEqual(parser.feed("\(header)\n- x\n"), [.under(index: 3, b("x", indent: 1, grey: true))], header)
        }
        for header in ["@new: Risks", "@NEW Risks", "@New:Risks", "@ new Risks"] {
            var parser = ExpansionParser(targets: targets)
            XCTAssertEqual(parser.feed("\(header)\n"), [.section(b("Risks", .heading2, grey: true))], header)
        }
        for header in ["@3x", "@3: more", "@newsletter ideas", "@new:", "@3,"] {
            var parser = ExpansionParser(targets: targets)
            XCTAssertEqual(parser.feed("\(header)\n- x\n"), [], header)
        }
    }

    func testHeaderSplitAcrossChunks() {
        var parser = ExpansionParser(targets: [b("A"), b("B")])
        XCTAssertEqual(parser.feed("@"), [])
        XCTAssertEqual(parser.feed("1:\n- x\n"), [.under(index: 1, b("x", indent: 1, grey: true))])
    }

    func testParserIndentsNestedBulletsAndClampsDepth() {
        var parser = ExpansionParser(targets: [b("Sub point", indent: 1)])
        let events = parser.feed("@0\n- a\n  - b\n      - c\n@new Next steps\n- d\n  - e\n")
        XCTAssertEqual(events, [
            .under(index: 0, b("a", indent: 2, grey: true)),
            .under(index: 0, b("b", indent: 3, grey: true)),
            .under(index: 0, b("c", indent: 3, grey: true)),
            .section(b("Next steps", .heading2, grey: true)),
            .bullet(b("d", grey: true)),
            .bullet(b("e", indent: 1, grey: true)),
        ])
    }

    // MARK: Expand all

    func testExpandAllKeepsAidansBlocksVerbatimAndWhite() async throws {
        let notes = [
            b("Pricing", .heading2),
            NoteBlock(kind: .bullet, runs: [.init(text: "Rates "), .init(text: "up", bold: true)]),
            b("Gift box", indent: 1),
        ]
        let claude = FakeClaude(["@0\n- first on pricing\n@2\n- gift ", "box detail\n@0\n- second on pricing\n@new Also\n- x\n"])
        let (blocks, yields) = try await last(Expander(claude: claude).expandAll(ctx(notes: notes)))

        XCTAssertEqual(blocks, [
            notes[0], b("first on pricing", indent: 1, grey: true), b("second on pricing", indent: 1, grey: true),
            notes[1],
            notes[2], b("gift box detail", indent: 2, grey: true),
            b("Also", .heading2, grey: true), b("x", grey: true),
        ])
        XCTAssertEqual(yields, 5, "one full list per event")
        XCTAssertEqual(blocks.filter { !$0.byClaude }, notes)
    }

    func testExpandAllWithNoNotesBuildsSections() async throws {
        let claude = FakeClaude(["@0\n- nowhere to go\n@new Decisions\n- Launch in March\n@new Next steps\n- Send quote\n"])
        let (blocks, _) = try await last(Expander(claude: claude).expandAll(ctx()))
        XCTAssertEqual(blocks, [
            b("Decisions", .heading2, grey: true), b("Launch in March", grey: true),
            b("Next steps", .heading2, grey: true), b("Send quote", grey: true),
        ])
        XCTAssertTrue(claude.lastPrompt.contains("<my_notes>"))
    }

    func testExpandAllWithOnlyJunkThrows() async {
        let claude = FakeClaude(["I'm sorry, I can't help with that."])
        do {
            _ = try await last(Expander(claude: claude).expandAll(ctx(notes: [b("Intro")])))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is ClaudeError)
        }
    }

    // MARK: Re-expand

    func testReExpandKeepsEditedGreyAndAddsNewNotes() async throws {
        let myNotes = [b("Pricing"), b("Gift box"), b("Timeline")]
        let oldGrey = b("old Claude detail", indent: 1, grey: true)
        let edited = b("Aidan rewrote this", indent: 1, grey: true)
        let expanded = [b("Pricing"), oldGrey, b("Timeline"), edited]
        let lyraWrote = ExpandedMerge.hashes(of: [oldGrey])
        let claude = FakeClaude(["@1\n- about the gift box\n@0\n- fresh on pricing\n"])

        let (blocks, _) = try await last(Expander(claude: claude).reExpand(
            myNotes: myNotes, expanded: expanded, lyraWrote: lyraWrote, ctx: ctx(notes: myNotes)))

        XCTAssertEqual(blocks, [
            b("Pricing"), b("fresh on pricing", indent: 1, grey: true),
            b("Gift box"), b("about the gift box", indent: 1, grey: true),
            b("Timeline"), b("Aidan rewrote this", indent: 1),
        ])
        XCTAssertTrue(claude.lastPrompt.contains("#1 - Gift box"), "indices refer to the white list")
        XCTAssertTrue(claude.lastPrompt.contains("#3   - Aidan rewrote this"))
        XCTAssertFalse(claude.lastPrompt.contains("old Claude detail"))
    }

    // MARK: Expand this, inject, ask

    func testExpandThisOnlyAcceptsTheSelectedBlock() async throws {
        let blocks = [b("Pricing"), b("earlier grey", indent: 1, grey: true), b("Timeline")]
        let claude = FakeClaude(["@2\n- wrong point\n@new Extra\n- no\n@0\n- more on pricing\n"])
        let result = try await Expander(claude: claude).expandThis("Pricing", block: 0, in: blocks, ctx: ctx(notes: [b("Pricing")]))
        XCTAssertEqual(result, [
            b("Pricing"), b("earlier grey", indent: 1, grey: true), b("more on pricing", indent: 1, grey: true),
            b("Timeline"),
        ])
        XCTAssertTrue(claude.lastPrompt.contains("Pricing"))
    }

    func testInjectAppendsSectionsAfterEveryBlock() async throws {
        let blocks = [b("Pricing"), b("grey", indent: 1, grey: true)]
        let claude = FakeClaude(["@new Morningside collab\n- Shared audience of early risers\n"])
        let result = try await Expander(claude: claude).inject("add a section on the Morningside collab", into: blocks, ctx: ctx())
        XCTAssertEqual(result, blocks + [b("Morningside collab", .heading2, grey: true), b("Shared audience of early risers", grey: true)])
        XCTAssertTrue(claude.lastPrompt.contains("Morningside collab"))
    }

    func testAskReturnsTrimmedPlainText() async throws {
        let claude = FakeClaude(["\n  Sam said the shoot ", "moves to Friday.  \n"])
        let answer = try await Expander(claude: claude).ask("When is the shoot?", about: "Timeline", ctx: ctx())
        XCTAssertEqual(answer, "Sam said the shoot moves to Friday.")
        XCTAssertTrue(claude.lastPrompt.contains("When is the shoot?"))
        XCTAssertTrue(claude.lastPrompt.contains("Timeline"))
    }

    // MARK: Context

    func testPromptCarriesNumberedNotesTranscriptAndConstraints() {
        let prompt = Prompts.expandUser(ctx: ctx(notes: [b("Pricing"), b("", .paragraph), b("Gift box")],
                                                 transcript: [line("Sam", 3725, "Rates go up in March.")]))
        for tag in ["<meeting>", "<my_notes>", "<transcript>", "<earlier_meetings>", "<task>", "<constraints>"] {
            XCTAssertTrue(prompt.contains(tag), tag)
        }
        XCTAssertTrue(prompt.contains("#0 - Pricing"))
        XCTAssertTrue(prompt.contains("#2 - Gift box"))
        XCTAssertTrue(prompt.contains("[01:02:05] Sam: Rates go up in March."))
        XCTAssertTrue(prompt.contains("Australian spelling"))
    }

    func testPromptRequiresAGroupForEveryOneOfAidansNotes() {
        let prompt = Prompts.expandUser(ctx: ctx(notes: [b("frameworks when approaching clients", .paragraph),
                                                         b("Gift box")]))
        XCTAssertTrue(prompt.contains("at least one @<n> group for every one of Aidan's numbered notes"))
        XCTAssertTrue(prompt.contains("heading or label"))
        XCTAssertTrue(prompt.contains("one-line summary of what the meeting said about that topic"))
        XCTAssertFalse(prompt.contains("Skip a note the transcript adds nothing to"))
    }

    func testContextTrimsLongTranscriptFromMiddle() {
        let lines = (0..<5_000).map { line("Sam", Double($0), "line number \($0) of a long meeting here") }
        let prompt = Prompts.expandUser(ctx: ctx(transcript: lines))
        XCTAssertTrue(prompt.contains("line number 0 of"))
        XCTAssertTrue(prompt.contains("line number 4999 of"))
        XCTAssertTrue(prompt.contains("[… trimmed …]"))
        XCTAssertFalse(prompt.contains("line number 2500 of"))
        XCTAssertLessThan(prompt.count, ContextBudget.transcriptChars + ContextBudget.earlierChars + 10_000)
    }

    func testEarlierMeetingsComeNewestFirstWithinBudget() {
        let earlier = (1...7).map { day in
            EarlierMeeting(title: "Catch-up \(day)", date: Date(timeIntervalSince1970: Double(day) * 86_400),
                           expanded: "notes \(day) " + String(repeating: "n", count: day == 7 ? 9_000 : 6_000),
                           transcript: "talk \(day) " + String(repeating: "t", count: 9_000))
        }
        let prompt = Prompts.expandUser(ctx: ctx(earlier: earlier))
        let positions = (3...7).map { prompt.range(of: "Catch-up \($0)")!.lowerBound }
        XCTAssertEqual(positions, positions.sorted(by: >), "newest first")
        XCTAssertNil(prompt.range(of: "Catch-up 2"), "only the five most recent")
        XCTAssertLessThan(prompt.range(of: "notes 7")!.lowerBound, prompt.range(of: "talk 7")!.lowerBound)
        let newestNotes = prompt[prompt.range(of: "notes 7 ")!.upperBound...]
        XCTAssertLessThan(newestNotes.prefix(while: { $0 == "n" }).count, ContextBudget.earlierExpandedChars)
        XCTAssertNotNil(prompt.range(of: "notes 3"), "expanded notes fill the budget before transcripts")
        XCTAssertLessThan(prompt.count, ContextBudget.earlierChars + 10_000)
    }
}
