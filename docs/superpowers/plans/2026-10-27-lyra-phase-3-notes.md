# Lyra Phase 3 — Notes App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Lyra into a Granola-style notes app: home window with series, a meeting window with My notes / Expanded / Transcript tabs and a live-transcript drawer, editable Claude-expanded notes, titles/tags/links/series, all stored in the Obsidian note itself.

**Architecture:** The Obsidian Markdown note is the single store for the three sections. LyraCore gains a small Markdown block model (parse ⇄ serialise, grey "by Claude" blocks), a note index found by `lyra_id`, a Claude CLI runner, and pure expansion/insight/series logic, all unit-tested with fakes. The app target gets an NSTextView-based editor, the home and meeting windows, and the live drawer. Recording code is not touched: live transcription reads the growing CAF files.

**Tech Stack:** Swift 6 (tools 6.0, Swift 6 mode), SwiftUI + AppKit (NSTextView), FluidAudio 0.17.7 (`SlidingWindowAsrManager` for live), ScreenCaptureKit + Vision (screen text), Claude Code CLI (`claude -p`) on Aidan's subscription.

**Spec:** `docs/superpowers/specs/2026-10-27-lyra-phase-3-notes-design.md` (read it; it wins on product questions). Whole-app design: `docs/superpowers/specs/2026-10-27-lyra-design.md`.

## Global Constraints

- Platform `.macOS(.v15)` floor, Apple Silicon, LSUIElement menu-bar app, bundle `au.aidos.lyra`.
- LyraCore imports Foundation (+ CryptoKit) only. AppKit/SwiftUI live in the `Lyra` target; ScreenCaptureKit/Vision in `LyraAudio`; FluidAudio in `LyraSpeech`.
- Notes root: `~/Documents/Obsidian Vault/Aidan Business/Meetings/` (`MeetingPaths.defaultNotesDir`). Clients list: folder names in `~/Documents/Obsidian Vault/Aidan Business/Clients/` (ignore `Index.md` and other files).
- **My notes is never modified** by Lyra or Claude — only by Aidan typing (in Lyra or Obsidian).
- Claude runs via `~/.local/bin/claude` (override env `CLAUDE_CLI_PATH`), env stripped of `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`; flags `--tools "" --setting-sources "" --strict-mcp-config --no-session-persistence`; prompt on **stdin**; model `sonnet` (constant `ClaudeCLI.defaultModel`).
- Formatting allowed in notes: `**bold**`, `<u>underline</u>`, `# `, `## `, `- ` bullets, `1. ` numbered, 2-space indent per level (max 3 levels). Nothing else is produced.
- Claude's text = a block wrapped as `<span class="lyra">…</span>` after its list marker/heading hashes. Grey is per block.
- Every file Lyra writes in the vault is written atomically (temp + rename). Nothing overwrites a file whose content changed since Lyra loaded it without asking.
- No network except the `claude` CLI. Screen images are never written to disk.
- Existing tests stay green: `swift test` (119+ tests). Integration tests gated by `LYRA_INTEGRATION=1`.
- Copy is plain English, Australian spelling.

## Review Focus

1. **Obsidian edit while Lyra's window is open** — Aidan types in Obsidian, then in Lyra: Lyra must reload or warn, never write over the Obsidian edit. → Task 3 test `testSaveRefusesWhenFileChangedOnDisk`, Task 11 handles the reload/warn.
2. **Note deleted, moved or with markers removed by hand** in Obsidian — Lyra must find it by `lyra_id` wherever it is in `Meetings/`, and treat a missing section as empty, not crash or recreate a duplicate. → Task 1 `testMissingSectionsReadAsEmpty`, Task 3 `testFindsMovedNoteByLyraID`.
3. **Claude unavailable or returns junk** (not logged in, usage limit, garbage format) — meeting stays complete, Expanded shows "Couldn't expand — Retry", no partial grey left half-written. → Task 5 `testNonZeroExitThrowsPlainError`, Task 6 `testUnparseableLinesAreIgnored`.
4. **Quit / crash mid-meeting while typing** — every typed word already on disk (≤ 1 s debounce) and the note is created at recording start. → Task 9 `testNoteSkeletonExistsWhenRecordingStarts`.
5. **Titles with `/`, `:` or emoji and duplicate titles** — file names stay legal and unique, links get rewritten exactly. → Task 3 `testRenameKeepsUniqueLegalNameAndRewritesLinks`.

---

## File map

LyraCore (new unless marked):
- `Notes/NoteBlocks.swift` — block model + Markdown parse/serialise.
- `Notes/NoteDocument.swift` — whole note: frontmatter fields + 3 sections; parse/render; Phase 1/2 compatibility.
- `Notes/NoteIndex.swift` — find notes by `lyra_id`, load/save with conflict check, rename/move with link rewrite.
- `Notes/ExpandedMerge.swift` — grey/white bookkeeping, re-expand merge, "new notes since" count, block move.
- `Notes/TranscriptSearch.swift` — find transcript lines for a selection.
- `Claude/ClaudeCLI.swift` — runner protocol + Process implementation + stream-json parsing.
- `Claude/Prompts.swift` — all prompts (one place).
- `Claude/Expander.swift` — expansion stream parser + operations (expand all, expand this, ask, inject, re-expand).
- `Claude/Insights.swift` — title, tags, links, series suggestion, one-line summary.
- `Series/SeriesLibrary.swift` — meetings grouped into series, suggestions, series page rendering.
- `Detection/IgnoredApps.swift` — persisted "always ignore".
- Modified: `Model/Meeting.swift`, `Output/NoteRenderer.swift`, `Pipeline/MeetingProcessor.swift`, `People/RenameService.swift`, `Detection/MeetingDetector.swift`.

LyraAudio: `ScreenText.swift` (window capture + OCR), `GrowingCAFReader.swift`.
LyraSpeech: `LiveTranscriber.swift`.
Lyra app: `HomeWindow.swift`, `NoteEditor.swift` (NSTextView wrapper), `MeetingWindow.swift` (rewritten), `LiveDrawer.swift`, modified `AppModel.swift`, `MenuContent.swift`, `LyraApp.swift`, `AllowPanel.swift`, `MeetingSession.swift`.

---

### Task 1: Note blocks and note document format

**Files:**
- Create: `Sources/LyraCore/Notes/NoteBlocks.swift`, `Sources/LyraCore/Notes/NoteDocument.swift`
- Modify: `Sources/LyraCore/Output/NoteRenderer.swift`, `Sources/LyraCore/Model/Meeting.swift`
- Test: `Tests/LyraCoreTests/NoteBlocksTests.swift`, `Tests/LyraCoreTests/NoteDocumentTests.swift`, update `NoteRendererTests.swift`

**Interfaces:**
- Produces:
  - `struct InlineRun: Equatable, Codable, Sendable { var text: String; var bold: Bool; var underline: Bool }`
  - `enum BlockKind: Equatable, Codable, Sendable { case paragraph, heading1, heading2, bullet, numbered }`
  - `struct NoteBlock: Equatable, Codable, Sendable { var kind: BlockKind; var indent: Int /*0...3*/; var runs: [InlineRun]; var byClaude: Bool; var plainText: String { get } }`
  - `enum NoteMarkdown { static func parse(_ md: String) -> [NoteBlock]; static func render(_ blocks: [NoteBlock]) -> String }`
  - `struct NoteFrontmatter: Equatable, Sendable { var lyraID: UUID; var title: String; var date: Date; var app: String; var durationMin: Int; var recordings: URL; var series: String?; var tags: [String]; var links: [String]; var summary: String? }`
  - `struct NoteDocument: Equatable, Sendable { var front: NoteFrontmatter; var warnings: [String]; var myNotes: String; var expanded: String; var transcript: String; static func parse(_ text: String) throws -> NoteDocument; func render() -> String }`
  - `NoteRenderer.render(meeting:lines:recordingsFolder:timeZone:)` now returns `NoteDocument(...).render()` with empty My notes/Expanded.
  - `Meeting` gains `var expandedHashes: [String]? = nil` (SHA-256 of each grey block's `NoteMarkdown.render([block])` as last written), `var seriesSuggestion: String? = nil`, `var seriesRejected: Bool? = nil`, `var screenText: [String]? = nil`, `var notePath: String? = nil` (last known path, a hint only).

- [ ] **Step 1: Write the failing tests**

```swift
func testRoundTripsAllAllowedFormatting() {
    let md = """
    # Big
    ## Small
    Plain **bold** and <u>under</u> text
    - point
      - child
    1. first
    2. second
    - <span class="lyra">Claude's detail</span>
    """
    let blocks = NoteMarkdown.parse(md)
    XCTAssertEqual(blocks.map(\.kind), [.heading1, .heading2, .paragraph, .bullet, .bullet, .numbered, .numbered, .bullet])
    XCTAssertEqual(blocks[4].indent, 1)
    XCTAssertEqual(blocks[2].runs, [InlineRun(text: "Plain ", bold: false, underline: false),
                                    InlineRun(text: "bold", bold: true, underline: false),
                                    InlineRun(text: " and ", bold: false, underline: false),
                                    InlineRun(text: "under", bold: false, underline: true),
                                    InlineRun(text: " text", bold: false, underline: false)])
    XCTAssertTrue(blocks[7].byClaude)
    XCTAssertEqual(blocks[7].plainText, "Claude's detail")
    XCTAssertEqual(NoteMarkdown.render(blocks), md)
}

func testUnknownMarkdownSurvivesAsPlainParagraph() {
    let md = "> a quote with [[Link]] and `code`"
    XCTAssertEqual(NoteMarkdown.render(NoteMarkdown.parse(md)), md)
}

// NoteDocumentTests
func testRendersThreeSectionsAndParsesBack() throws { /* doc with myNotes "- hi", expanded "- <span class=\"lyra\">x</span>", transcript "**Aidan** [00:00:01] hello", series "Elm Park Startup Series", tags ["ai-consulting"], links ["Northwind"], summary "Kick-off"; render → contains "## My notes", "## Expanded", "## Transcript", "series: \"Elm Park Startup Series\"", "tags: [meeting, ai-consulting]", "links: [\"[[Northwind]]\"]"; parse(render) == doc */ }
func testMissingSectionsReadAsEmpty() throws { /* note with frontmatter + only transcript markers → myNotes == "" && expanded == "" */ }
func testReadsPhase2NoteNotesMarkersAsMyNotes() throws { /* "<!-- lyra:notes:start -->\n- typed\n<!-- lyra:notes:end -->" → myNotes == "- typed" */ }
func testKeepsTextOutsideSectionsWhenReRendered() throws { /* extra paragraph Aidan added after the title survives parse→render byte-for-byte */ }
```

- [ ] **Step 2: Run** `swift test --filter 'NoteBlocksTests|NoteDocumentTests'` — Expected: FAIL (types not defined).

- [ ] **Step 3: Implement.** Section markers: `<!-- lyra:mynotes:start/end -->`, `<!-- lyra:expanded:start/end -->`, existing `<!-- lyra:transcript:start/end -->` (keep `NoteSections` working on the transcript one). Headings in the file: `## My notes`, `## Expanded`, `## Transcript`. `NoteDocument` keeps any text outside the sections in a `preserved` field so re-rendering doesn't drop Aidan's own additions (store the note as an ordered list of literal chunks + section bodies). Frontmatter `tags` always starts with `meeting`; `links` rendered as quoted `[[Name]]`. Escape `<!--` inside section bodies as `NoteRenderer` already does. Inline parser handles only `**` and `<u>`; any other syntax stays literal text in a run.

- [ ] **Step 4: Run** `swift test` — Expected: all pass (update `NoteRendererTests` expectations for the new headings/markers).

- [ ] **Step 5: Commit** `git commit -m "feat(notes): markdown block model and three-section note document"`

---

### Task 2: Expanded bookkeeping — grey/white, re-expand merge, block moves, transcript search

**Files:**
- Create: `Sources/LyraCore/Notes/ExpandedMerge.swift`, `Sources/LyraCore/Notes/TranscriptSearch.swift`
- Test: `Tests/LyraCoreTests/ExpandedMergeTests.swift`, `Tests/LyraCoreTests/TranscriptSearchTests.swift`

**Interfaces:**
- Consumes: `NoteBlock`, `NoteMarkdown` (Task 1).
- Produces:
  - `enum ExpandedMerge`
    - `static func hashes(of blocks: [NoteBlock]) -> [String]` — hashes of `byClaude` blocks.
    - `static func settle(_ blocks: [NoteBlock], lyraWrote: [String]) -> [NoteBlock]` — a `byClaude` block whose hash isn't in `lyraWrote` was edited (in Obsidian) → `byClaude = false`.
    - `static func newNotes(myNotes: [NoteBlock], expanded: [NoteBlock]) -> [NoteBlock]` — My-notes blocks whose normalised text (lowercased, whitespace-collapsed) matches no white Expanded block.
    - `static func insertNewNotes(_ new: [NoteBlock], myNotes: [NoteBlock], into expanded: [NoteBlock]) -> [NoteBlock]` — each new block goes after the Expanded block matching its predecessor in My notes (and that block's grey children), else at the end.
    - `static func stripGrey(_ blocks: [NoteBlock]) -> [NoteBlock]` — drops `byClaude` blocks (used before re-expand).
    - `static func moveBlock(_ blocks: [NoteBlock], from: Int, to: Int) -> [NoteBlock]` — moves the block and its deeper-indented children as a unit; headings carry everything until the next heading of same or higher level.
  - `enum TranscriptSearch { static func lines(matching selection: String, in lines: [TranscriptLine], limit: Int = 3) -> [Int] }` — indices ranked by shared non-stopword count, ties by time.

- [ ] **Step 1: Write the failing tests**

```swift
func testEditedGreyBecomesWhite() {
    let grey = NoteBlock(kind: .bullet, indent: 1, runs: [.init(text: "detail", bold: false, underline: false)], byClaude: true)
    var edited = grey; edited.runs[0].text = "detail, edited"
    let settled = ExpandedMerge.settle([grey, edited], lyraWrote: ExpandedMerge.hashes(of: [grey]))
    XCTAssertEqual(settled.map(\.byClaude), [true, false])
}
func testNewNotesSinceExpansionCountsOnlyUncoveredPoints() { /* myNotes ["Pricing","Xmas reels","Gift box"], expanded white ["pricing","Xmas reels"] + grey → newNotes == ["Gift box"] */ }
func testInsertNewNotesAfterPredecessorAndItsGreyChildren() { /* "Gift box" lands after "Xmas reels" and its grey child, before "Pricing" heading */ }
func testMoveBlockCarriesChildren() { /* move bullet with 2 children from 0 to end → children follow */ }
func testMoveHeadingCarriesSection() { /* ## A, - a1, ## B → move A after B section */ }
func testTranscriptSearchRanksSharedWords() { /* selection "gift box budget" → index of "the gift box budget is about six hundred" first */ }
```

- [ ] **Step 2: Run** `swift test --filter 'ExpandedMergeTests|TranscriptSearchTests'` — FAIL.
- [ ] **Step 3: Implement** as specified (hash = `NoteSections.hash(NoteMarkdown.render([block]))`).
- [ ] **Step 4: Run** `swift test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(notes): grey/white bookkeeping, re-expand merge, block moves, transcript search"`

---

### Task 3: Note index — find by lyra_id, safe load/save, rename/move with link rewrite

**Files:**
- Create: `Sources/LyraCore/Notes/NoteIndex.swift`
- Modify: `Sources/LyraCore/Output/MeetingPaths.swift` (reuse `sanitise` for note names), `Sources/LyraCore/People/RenameService.swift` (take the note URL from `NoteIndex`, unchanged behaviour)
- Test: `Tests/LyraCoreTests/NoteIndexTests.swift`

**Interfaces:**
- Consumes: `NoteDocument` (Task 1), `MeetingPaths.sanitise`.
- Produces:
  - `struct LoadedNote: Sendable { let url: URL; let document: NoteDocument; let fingerprint: String /*SHA-256 of file bytes*/ }`
  - `enum NoteIndexError: Error, LocalizedError { case notFound(UUID), changedOnDisk(URL) }` — plain-English descriptions.
  - `struct NoteIndex: Sendable`
    - `init(notesRoot: URL, vaultRoot: URL)` — vaultRoot = `Aidan Business/`.
    - `func find(_ id: UUID, hint: URL?) -> URL?` — hint first, else recursive scan of `notesRoot` for `lyra_id: <id>` in frontmatter.
    - `func load(_ id: UUID, hint: URL?) throws -> LoadedNote`
    - `func save(_ document: NoteDocument, over loaded: LoadedNote) throws -> LoadedNote` — throws `.changedOnDisk` if the file's current fingerprint ≠ `loaded.fingerprint`; atomic write.
    - `func relocate(_ loaded: LoadedNote, title: String, series: String?) throws -> LoadedNote` — target `notesRoot/<series?>/<yyyy-MM-dd HHmm — title>.md` (unique with " (2)"…, sanitised), moves file, rewrites `[[Old name]]`, `[[Old name|alias]]`, `[[Old name#…]]` in every `.md` under `vaultRoot` (exact matches only, atomic writes), returns new note.
    - `func renameSeriesFolder(from: String, to: String) throws` — moves the folder and updates `series:` in each note inside + links to the series page.
    - `func allNotes() -> [LoadedNote]` — every Lyra note under `notesRoot` (has `lyra_id`).

- [ ] **Step 1: Write the failing tests** (temp dirs)

```swift
func testFindsMovedNoteByLyraID() throws { /* write note, move it into Meetings/Some Series/, find(id, hint: oldURL) == newURL */ }
func testSaveRefusesWhenFileChangedOnDisk() throws { /* load, append text to the file directly, save → throws changedOnDisk; file still has the appended text */ }
func testRenameKeepsUniqueLegalNameAndRewritesLinks() throws {
    // note titled "Google Chrome"; other note links [[2026-10-27 0405 — Google Chrome]] and [[2026-10-27 0405 — Google Chrome|alias]]
    // relocate(title: "Workshop 2: Strategy / Q&A", series: "Elm Park Startup Series")
    // → file at Meetings/Elm Park Startup Series/2026-10-27 0405 — Workshop 2 Strategy Q&A.md (whatever sanitise yields, no "/" or ":")
    // → both links now point at the new name, alias kept; a second relocate to the same title yields " (2)"
}
func testRenameSeriesFolderUpdatesNotes() throws { /* series: field and folder renamed */ }
```

- [ ] **Step 2: Run** `swift test --filter NoteIndexTests` — FAIL.
- [ ] **Step 3: Implement.** Scanning reads only the first 40 lines of each `.md`. Cache nothing across calls (scan cost is tiny at this scale).
- [ ] **Step 4: Run** `swift test` — PASS (RenameService tests still green).
- [ ] **Step 5: Commit** `git commit -m "feat(notes): note index by lyra_id with safe saves and link-preserving renames"`

---

### Task 4: Always ignore an app

**Files:**
- Create: `Sources/LyraCore/Detection/IgnoredApps.swift`
- Modify: `Sources/LyraCore/Detection/MeetingDetector.swift`, `Sources/Lyra/AllowPanel.swift`, `Sources/Lyra/AppModel.swift`, `Sources/Lyra/MenuContent.swift`
- Test: `Tests/LyraCoreTests/IgnoredAppsTests.swift`, `MeetingDetectorTests.swift`

**Interfaces:**
- Produces:
  - `struct IgnoredApp: Codable, Hashable, Sendable { let key: String /*bundleID, or "name:<appName>" when bundleID is ""*/; let name: String; init(user: MicUser) }`
  - `final class IgnoredApps: @unchecked Sendable { init(defaults: UserDefaults, key: String = "ignoredApps"); func all() -> [IgnoredApp]; func add(_ app: IgnoredApp); func remove(_ app: IgnoredApp); func contains(_ user: MicUser) -> Bool }`
  - `MeetingDetector.init(ownPID:ignore: @escaping (MicUser) -> Bool, endGrace:)` replaces the bundle-ID set (Lyra's own bundle stays ignored via the closure).

- [ ] **Step 1: Failing tests** — `testIgnoredAppPersistsAcrossInstances` (suite-named UserDefaults), `testAppWithoutBundleIDIgnoredByName`, `testDetectorSkipsIgnoredApp` (closure ignoring zoom → no `.meetingStarted(zoom)`).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** AllowPanel gets a third button "Always ignore <app>" (panel height grows to fit). Menu gets an "Ignored apps" submenu listing each with a click to stop ignoring.
- [ ] **Step 4: Run** `swift test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(detect): always ignore an app from the Allow popup"`

---

### Task 5: Claude CLI runner

**Files:**
- Create: `Sources/LyraCore/Claude/ClaudeCLI.swift`
- Test: `Tests/LyraCoreTests/ClaudeCLITests.swift` (uses a fake executable script written to a temp dir), integration check in `Tests/LyraIntegrationTests/ClaudeCLIIntegrationTests.swift` (gated, one real tiny call)

**Interfaces:**
- Produces:
  - `protocol ClaudeRunning: Sendable { func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> }` — yields text deltas; finishes after the result event.
  - `extension ClaudeRunning { func complete(system: String, prompt: String, model: String = ClaudeCLI.defaultModel) async throws -> String }` — joins deltas.
  - `struct ClaudeCLI: ClaudeRunning { static let defaultModel = "sonnet"; init(executable: URL = …, timeout: Duration = .seconds(300), environment: [String:String] = ProcessInfo.processInfo.environment) }`
  - `enum ClaudeError: Error, LocalizedError { case notInstalled, failed(String), timedOut }` — messages: "Claude Code isn't installed on this Mac.", "Claude couldn't answer: <detail>", "Claude took too long to answer."
  - `static func subscriptionEnvironment(_ env: [String:String]) -> [String:String]` (strips the three keys).
- Args: `-p --model <m> --system-prompt <s> --tools "" --setting-sources "" --strict-mcp-config --no-session-persistence --output-format stream-json --verbose --include-partial-messages`; prompt written to stdin; cwd = `FileManager.default.temporaryDirectory`. Parse each stdout line as JSON: `type == "stream_event"` with `event.delta.type == "text_delta"` → yield `event.delta.text`; `type == "result"` with `is_error == true` → throw `.failed(result)`; non-zero exit with no result → `.failed(stderr tail)`.

- [ ] **Step 1: Failing tests** — `testStripsSubscriptionBreakingKeys`, `testYieldsTextDeltasInOrder` (fake script echoes three stream_event lines + result), `testNonZeroExitThrowsPlainError`, `testMissingExecutableThrowsNotInstalled`, `testPromptGoesThroughStdin` (fake script `cat`s stdin into a file).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** with `Process`, pipes read on a background task line by line; timeout terminates the process.
- [ ] **Step 4: Run** `swift test` — PASS; then `LYRA_INTEGRATION=1 swift test --filter ClaudeCLIIntegrationTests` — PASS (prints the reply to "Reply with the word ok").
- [ ] **Step 5: Commit** `git commit -m "feat(claude): subscription CLI runner with streaming"`

---

### Task 6: Prompts and the expander

**Files:**
- Create: `Sources/LyraCore/Claude/Prompts.swift`, `Sources/LyraCore/Claude/Expander.swift`
- Test: `Tests/LyraCoreTests/ExpanderTests.swift` (fake `ClaudeRunning` yielding scripted chunks)

**Interfaces:**
- Consumes: `ClaudeRunning` (Task 5), `NoteBlock`/`NoteMarkdown` (Task 1), `ExpandedMerge` (Task 2), `TranscriptLine`.
- Produces:
  - `struct MeetingContext: Sendable { var title: String; var myNotes: [NoteBlock]; var transcript: [TranscriptLine]; var earlier: [EarlierMeeting] }`, `struct EarlierMeeting: Sendable { var title: String; var date: Date; var expanded: String; var transcript: String }`
  - `enum ContextBudget { static let transcriptChars = 120_000; static let earlierChars = 40_000; static let earlierMeetings = 5; static let earlierExpandedChars = 8_000 }` — this meeting's transcript is cut from the middle with a "[… trimmed …]" line if over; earlier meetings newest first, expanded notes before transcripts.
  - `enum ExpansionEvent: Equatable, Sendable { case under(index: Int, NoteBlock), section(NoteBlock /*heading2, byClaude*/), bullet(NoteBlock /*under the latest section*/) }`
  - `struct ExpansionParser { mutating func feed(_ chunk: String) -> [ExpansionEvent]; mutating func finish() -> [ExpansionEvent] }` — line protocol Claude is asked to use:
    ```
    @3                 ← following bullets go under Aidan's block #3 (0-based)
    - detail
      - deeper detail
    @new Heading text  ← a new section of things he didn't note
    - bullet
    ```
    Lines before any `@` or not matching are ignored. Produced blocks have `byClaude = true`, indent = Aidan's block indent + 1 + leading-space level for `@n`, 0/1 for `@new`.
  - `struct Expander: Sendable { init(claude: ClaudeRunning) }`
    - `func expandAll(_ ctx: MeetingContext) -> AsyncThrowingStream<[NoteBlock], Error>` — yields the full Expanded block list after each event (Aidan's blocks white, verbatim; when My notes is empty, only `@new` sections).
    - `func expandThis(_ selection: String, block: Int, in blocks: [NoteBlock], ctx: MeetingContext) async throws -> [NoteBlock]` — grey bullets inserted under `block`.
    - `func ask(_ question: String, about selection: String?, ctx: MeetingContext) async throws -> String` — plain answer (2–6 sentences).
    - `func inject(_ idea: String, into blocks: [NoteBlock], ctx: MeetingContext) async throws -> [NoteBlock]` — appends `@new` sections (or `@n` additions) for the idea.
    - `func reExpand(myNotes: [NoteBlock], expanded: [NoteBlock], lyraWrote: [String], ctx: MeetingContext) -> AsyncThrowingStream<[NoteBlock], Error>` — `settle` → `insertNewNotes` → `stripGrey` → expansion of the white blocks.
  - `Prompts` holds `expandSystem`, `expandUser(ctx:)`, `expandThis…`, `ask…`, `inject…`, each with XML tags `<meeting>`, `<my_notes>` (blocks numbered `#0…`), `<transcript>` (`[hh:mm:ss] Name: text`), `<earlier_meetings>`, `<task>`, `<constraints>` (never repeat or rewrite Aidan's lines; use names as given; Australian spelling; no invented facts — only what the transcript or earlier meetings support; bullets ≤ 25 words) and a short "first list ways this could go wrong, then answer" instruction kept out of the output (ask for the check silently; output only the line protocol).

- [ ] **Step 1: Failing tests**
  - `testParserHandlesChunksSplitMidLine` (feed `"@1\n- de"`, `"tail\n@new Risks\n- one\n"` → under(1,"detail"), section("Risks"), bullet("one")).
  - `testUnparseableLinesAreIgnored` (prose + `@x` + `@99` beyond range → no events / dropped).
  - `testExpandAllKeepsAidansBlocksVerbatimAndWhite`.
  - `testExpandAllWithNoNotesBuildsSections`.
  - `testReExpandKeepsEditedGreyAndAddsNewNotes`.
  - `testContextTrimsLongTranscriptFromMiddle` (budget overflow → contains first and last lines and "[… trimmed …]").
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(claude): expansion prompts, streaming parser and note operations"`

---

### Task 7: Insights — title, tags, links, series suggestion, one-liner; screen text

**Files:**
- Create: `Sources/LyraCore/Claude/Insights.swift`, `Sources/LyraAudio/ScreenText.swift`
- Modify: `Sources/LyraCore/Claude/Prompts.swift`
- Test: `Tests/LyraCoreTests/InsightsTests.swift`; gated `Tests/LyraIntegrationTests/ScreenTextTests.swift`

**Interfaces:**
- Produces:
  - `struct MeetingInsights: Codable, Equatable, Sendable { var title: String; var tags: [String]; var clients: [String]; var series: String?; var summary: String }`
  - `struct InsightsInput: Sendable { var windowTitle: String; var screenText: [String]; var transcript: [TranscriptLine]; var myNotes: String; var existingSeries: [String: [String]] /*series → recent titles*/; var knownTags: [String]; var clients: [String]; var people: [String] }`
  - `enum InsightsService { static func run(_ input: InsightsInput, claude: ClaudeRunning) async throws -> MeetingInsights; static func parse(_ json: String, input: InsightsInput) throws -> MeetingInsights }` — Claude returns one JSON object; `parse` tolerates a ```json fence; validates: title 3–80 chars (else window title), tags lowercase-hyphenated, max 6, prefer `knownTags`; `clients` kept only if exactly in `input.clients`; `series` is an existing name, a new name, or nil; summary one sentence ≤ 140 chars.
  - `static func knownTags(in notes: [LoadedNote]) -> [String]`, `static func clients(inVault: URL) -> [String]` (folder names under `Clients/`).
  - LyraAudio: `enum ScreenText { static func read(pid: pid_t) async -> [String] }` — ScreenCaptureKit `SCShareableContent` → frontmost on-screen window of the owning app → `SCScreenshotManager.captureImage` → `VNRecognizeTextRequest` (.accurate, en-AU) → lines ≥ 3 chars; returns [] without permission or on any error. The image is never written.

- [ ] **Step 1: Failing tests** — `testParsesFencedJSON`, `testFallsBackToWindowTitleWhenTitleUnusable`, `testDropsUnknownClients`, `testNormalisesTags` ("Content Strategy" → "content-strategy", max 6), `testSuggestsExistingSeriesNameVerbatim` (fake Claude returns "elm park startup series" → matches existing "Elm Park Startup Series" case-insensitively).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` — PASS; `LYRA_INTEGRATION=1 swift test --filter ScreenTextTests` reads a Finder window title (skips without permission).
- [ ] **Step 5: Commit** `git commit -m "feat(claude): meeting insights and on-screen text"`

---

### Task 8: Series library and series pages

**Files:**
- Create: `Sources/LyraCore/Series/SeriesLibrary.swift`
- Test: `Tests/LyraCoreTests/SeriesLibraryTests.swift`

**Interfaces:**
- Consumes: `NoteIndex`, `LoadedNote`, `Meeting` (Tasks 1, 3).
- Produces:
  - `struct MeetingSummary: Identifiable, Equatable, Sendable { let id: UUID; var title: String; var date: Date; var series: String?; var tags: [String]; var summary: String?; var suggestion: String?; var folder: URL?; var note: URL }`
  - `struct SeriesGroup: Equatable, Sendable { let name: String; var meetings: [MeetingSummary] /*newest first*/; var tags: [String] /*union, top 3*/ }`
  - `enum SeriesLibrary`
    - `static func summaries(notes: [LoadedNote], meetingsByID: [UUID: (Meeting, URL)]) -> [MeetingSummary]`
    - `static func groups(_ s: [MeetingSummary]) -> [SeriesGroup]` — sorted by newest meeting.
    - `static func pendingSuggestions(_ s: [MeetingSummary]) -> [MeetingSummary]` — has suggestion, not rejected, no series.
    - `static func seriesPage(name: String, meetings: [MeetingSummary], notesRoot: URL) -> String` — frontmatter `lyra_series: true`, `# <name>`, then oldest→newest lines `- [[<note file name>|<title>]] — <date d MMM yyyy> — <summary>`.
    - `static func writeSeriesPage(name: String, index: NoteIndex) throws` — writes `Meetings/<name>/<name>.md` (atomic); excluded from `allNotes()` by `lyra_series`.

- [ ] **Step 1: Failing tests** — `testGroupsBySeriesNewestFirst`, `testPendingSuggestionHiddenOnceRejectedOrConfirmed`, `testSeriesPageListsOldestFirstWithOneLiners` (exact expected text for two meetings), `testFolderOverridesFrontmatterSeries` (note moved by hand into `Meetings/X/` while frontmatter says nothing → summary.series == "X").
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(series): series grouping, suggestions and series pages"`

---

### Task 9: Pipeline — note at start, transcript, insights, rename/move, expansion

**Files:**
- Modify: `Sources/LyraCore/Pipeline/MeetingProcessor.swift`, `Sources/Lyra/MeetingSession.swift`, `Sources/Lyra/AppModel.swift`, `Sources/LyraCore/People/RenameService.swift`
- Create: `Sources/LyraCore/Pipeline/AfterMeeting.swift`
- Test: `Tests/LyraCoreTests/MeetingProcessorTests.swift` (extend), `Tests/LyraCoreTests/AfterMeetingTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 5–8.
- Produces:
  - `MeetingProcessor.createSkeletonNote(for meeting: Meeting, recordingsFolder: URL, at noteURL: URL) throws` — called by `MeetingSession.init` right after `reserve`; exclusive create; empty My notes / Expanded / Transcript sections.
  - `process(...)` now fills the transcript section of the existing note via `NoteIndex` (finding it by `lyra_id`, so it may have moved) instead of creating the note; still creates it if missing (crash before skeleton). Ordering/crash-safety rules unchanged otherwise. Stores `notePath` hint in `meeting.json`.
  - `struct AfterMeeting: Sendable { init(index: NoteIndex, claude: ClaudeRunning, expander: Expander, vaultRoot: URL); func run(folder: URL) async throws }` — loads meeting + note + transcript; runs `InsightsService`; writes title/tags/links/summary into frontmatter; sets `seriesSuggestion` (always a suggestion, never an automatic join — spec 5.4); `relocate`s the note to its title (no series yet); then streams `expandAll`, saving the Expanded section at most every 1 s and at the end; records `expandedHashes`. A failure at any step leaves earlier steps saved and records `meeting.expandError` (new optional String) for the UI's Retry.
  - `AppModel`: after `process` succeeds, runs `AfterMeeting` (same serial queue); exposes `@Published var liveExpansion: [UUID: [NoteBlock]]` so an open meeting window can show it streaming.
  - Screen text: `MeetingSession` calls `ScreenText.read(pid:)` at start and every 60 s while recording, keeps distinct lines (max 200), saves them to `meeting.screenText`.

- [ ] **Step 1: Failing tests** — `testNoteSkeletonExistsWhenRecordingStarts` (skeleton has lyra_id, empty sections), `testProcessFillsTranscriptOfMovedSkeleton` (skeleton moved into a subfolder → transcript lands there, no duplicate), `testProcessKeepsTypedMyNotes`, `testAfterMeetingWritesInsightsAndExpansion` (fake Claude: insights JSON then expansion lines → frontmatter title/tags/summary, file renamed, Expanded has grey blocks, `expandedHashes` set), `testAfterMeetingClaudeFailureKeepsNoteAndRecordsError`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** RenameService and MeetingModel find the note through `NoteIndex` (hint = `meeting.notePath`) instead of `notesDir + folder name`.
- [ ] **Step 4: Run** `swift test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(pipeline): note from the start, insights, renaming and expansion after the meeting"`

---

### Task 10: Live transcript

**Files:**
- Create: `Sources/LyraAudio/GrowingCAFReader.swift`, `Sources/LyraSpeech/LiveTranscriber.swift`
- Modify: `Sources/Lyra/MeetingSession.swift`
- Test: gated `Tests/LyraIntegrationTests/LiveTranscriptTests.swift`; `Tests/LyraCoreTests/LiveLinesTests.swift` for the pure line bookkeeping

**Interfaces:**
- Produces:
  - LyraCore `struct LiveLine: Identifiable, Equatable, Sendable { let id: UUID; let track: TrackKind; var text: String; var isFinal: Bool }`, `struct LiveLines { mutating func apply(track: TrackKind, text: String, isFinal: Bool); var lines: [LiveLine] }` — volatile text replaces the track's last non-final line; final text closes it; label in UI: `.mic` → "Me", `.meeting` → "Them".
  - LyraAudio `final class GrowingCAFReader { init(url: URL); func readNew() throws -> AVAudioPCMBuffer? }` — reopens the file each call, reads frames from the last position, returns nil when nothing new.
  - LyraSpeech `actor LiveTranscriber { init(folder: URL, tracks: [TrackKind]); func start() async throws; func stop() async; var updates: AsyncStream<(TrackKind, String, Bool)> }` — one `SlidingWindowAsrManager` per track (`.microphone` for mic, `.system` for meeting), English, fed by polling each CAF every 1 s.
- **Risk to settle in Step 1:** reading a CAF while `ExtAudioFileWriteAsync` is still writing it. If the integration test can't read growing frames, switch `GrowingCAFReader`'s source to a lock-free copy from the recorders' tap (`CAFWriter.write` gets an optional `(UnsafePointer<AudioBufferList>) -> Void` side-sink that copies into an `Atomic`-indexed ring buffer — no locks or allocation on the audio thread) and note it in `docs/notes/phase3-findings.md`.
- Live failure never stops recording: errors end the stream and the drawer shows "Live transcript stopped — the full transcript will still be made after the meeting."

- [ ] **Step 1: Write the gated test** `testReadsFramesWhileFileIsBeingWritten` (start `MicRecorder`-style `CAFWriter` writing a 440 Hz tone, read twice 1 s apart → second read returns > 0 frames) and `testLiveTranscribesFixtureSpeech` (stream the existing fixture WAV into a CAF in real time-ish chunks → updates contain "hello" or a fixture word). Pure `LiveLinesTests` for apply().
- [ ] **Step 2: Run** `LYRA_INTEGRATION=1 swift test --filter LiveTranscriptTests` — FAIL.
- [ ] **Step 3: Implement**; `MeetingSession` starts `LiveTranscriber` after recording starts and stops it before `recorder.stop()` returns its results.
- [ ] **Step 4: Run** gated + full `swift test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(live): live transcript from the growing recordings"`

---

### Task 11: Editor, meeting window, home window, menu

**Files:**
- Create: `Sources/Lyra/NoteEditor.swift`, `Sources/Lyra/HomeWindow.swift`, `Sources/Lyra/LiveDrawer.swift`, `Sources/LyraCore/Notes/NoteText.swift` (Foundation-only attributed-string bridge)
- Modify: `Sources/Lyra/MeetingWindow.swift` (rewrite), `Sources/Lyra/LyraApp.swift`, `Sources/Lyra/MenuContent.swift`, `Sources/Lyra/AppModel.swift`
- Test: `Tests/LyraCoreTests/NoteTextTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - LyraCore `enum NoteText` with custom `NSAttributedString.Key`s `lyraBlockKind`, `lyraIndent`, `lyraBold`, `lyraUnderline`, `lyraByClaude`: `static func attributed(_ blocks: [NoteBlock]) -> NSAttributedString`, `static func blocks(_ text: NSAttributedString) -> [NoteBlock]`, `static func shortcut(forLinePrefix: String) -> (BlockKind, consumed: Int)?` (`"- "`, `"* "` → bullet; `"1. "` → numbered; `"# "` → heading1; `"## "` → heading2), `static func continuation(after block: NoteBlock) -> NoteBlock?` (Return on a non-empty list item continues the list, numbering +1; Return on an empty item ends the list).
  - `NoteEditor: NSViewRepresentable` around `NSTextView`: styles by the custom keys (serif title font is outside the editor; body 15 pt system; heading1 22 pt semibold, heading2 18 pt semibold; grey = `.secondaryLabelColor`); ⌘B, ⌘U; Tab/⇧Tab indent; markdown shortcuts as typed; typing inside a grey block clears `lyraByClaude` for that block; drag handle (⋮⋮) shown in the left gutter on hover for the hovered block, dragging calls `ExpandedMerge.moveBlock`; ⌥⌘↑/↓ also move the block; selection shows a small floating menu: **Expand this · Find in transcript · Ask…** (only on the Expanded tab); `onChange([NoteBlock])` debounced 1 s.
  - **Meeting window**: editable serif title; meta line (date · series chip or "Add to series?" suggestion with Add / Not related · tags · links); tabs My notes / Expanded / Transcript; Expanded shows streaming blocks while `liveExpansion` has them, then "Couldn't expand — Retry" on error, and "N new notes since — Re-expand" when `ExpandedMerge.newNotes` is non-empty, plus a **Re-expand** menu item; bottom bar "Ask anything or add an idea…" → `Expander.ask` answer shown under the bar with **Add to notes** (appends a grey paragraph) or, when the text starts with "add"/"include"/"weave", `Expander.inject`; Transcript tab = Phase 2 speaker list + rename + lines, and *Find in transcript* scrolls/highlights the lines from `TranscriptSearch`; during recording, a bottom toggle opens `LiveDrawer` (hidden by default). File changes: the window watches its note (`DispatchSource` file-system object source on the URL, re-armed after atomic replaces) and reloads when there are no unsaved edits; with unsaved edits it shows "This note changed in Obsidian — Reload / Keep mine (overwrite)".
  - **Home window** (`Window("Lyra", id: "home")`): New note button while recording; Series groups; suggestion cards; Recent list; rename series (context menu) via `NoteIndex.renameSeriesFolder`; move meeting to series via the meeting window's series chip. Confirming a series: set `series:` → `relocate` → `writeSeriesPage`.
  - Menu: first item **Open Lyra** (home), **New note** while recording; "Open last meeting" removed (home replaces it). Keep Stop / Start in person / Teach my voice / Ignored apps / Quit.

- [ ] **Step 1: Failing tests** — `testAttributedRoundTrip` (blocks → attributed → blocks equal), `testShortcutRecognition`, `testListContinuationNumbersUp`, `testEmptyListItemEndsList`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** LyraCore bridge, then the views. Keep each view file under ~300 lines; put view state in small `@MainActor` model classes beside the views.
- [ ] **Step 4: Run** `swift test` — PASS; `scripts/build-app.sh` builds; launch `build/Lyra.app`, open home and an existing meeting (`2026-10-27 0409 — Google Chrome`), type in My notes, confirm the `.md` updates within ~1 s, edit the file in another editor and confirm the window reloads. Take screenshots of home, each tab, the live drawer and the selection menu into `docs/notes/phase3-screens/` (gitignored if large) for Aidan.
- [ ] **Step 5: Commit** `git commit -m "feat(app): notes editor, meeting and home windows, live drawer"`

---

### Task 12: Acceptance with Aidan (👤 human-driven, agent assists)

- [ ] **Step 1:** Rebuild and restart Lyra (`scripts/build-app.sh`, quit old, `open build/Lyra.app`).
- [ ] **Step 2:** Aidan checks, on a real call:
  1. Dictation doesn't prompt; "Always ignore" works on a non-meeting app.
  2. New note during the call; typing feels like a blank canvas (bullets, numbered, bold, underline, two headings); live drawer toggles.
  3. After the call: title, tags, client link and one-liner look right; series suggestion appears for a repeat meeting and Add moves it into the series folder with a series page.
  4. Expanded streams in; drag a point, highlight → Expand this / Find in transcript / Ask; bottom-bar question and idea injection.
  5. Edit a grey line in Obsidian → Re-expand leaves it alone; type a new point in My notes → "1 new note since" → Re-expand covers it.
  6. Obsidian shows all three sections; editing there shows in Lyra.
- [ ] **Step 3:** Record findings in `docs/notes/phase3-findings.md`; commit.

---

## Self-review notes

- Spec coverage: 5.1 → T8/T11; 5.2 + live drawer → T9/T10/T11; 5.3 → T2/T6/T11; 5.4 → T8/T11; 5.5 → T7/T9; 5.6 → T1/T3/T11; 5.7 → T5; 5.8 → T4; §6 calls (series folders, no auto-popup, answers with Add to notes, re-expand rule, file names follow title, Obsidian moves = join series via lyra_id scan + `series:` from folder in `SeriesLibrary.summaries`) → T3/T6/T8/T9/T11.
- Obsidian move into a series folder: `SeriesLibrary.summaries` takes `series` from the note's parent folder when it's a direct child of `Meetings/` and differs from frontmatter, and the next save writes it into frontmatter (Task 8 `testFolderOverridesFrontmatterSeries`).
