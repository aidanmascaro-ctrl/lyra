# Lyra Phase 2 — People Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lyra learns voices. Each speaker cluster gets a voice fingerprint, known people are named automatically when confident, Aidan can teach Lyra his own voice, and any "Speaker N" can be renamed from a post-meeting window, which also teaches Lyra that voice for future meetings. Plus the fixes from the 2026-10-27 real-call tests.

**Architecture:** Diarization now returns each cluster's centroid embedding alongside its turns. A `PeopleStore` (JSON in Application Support, local only) holds people and their voice samples. A pure `VoiceMatcher` assigns clusters to people with a confidence and a margin. `SpeakerNamer` turns raw cluster labels into names or "Speaker N" and merges clusters that belong to the same person (fixes Aidan's mic voice being split in two). `RenameService` applies a rename to one meeting, learns the voice, and rewrites only the note's marked transcript section. The SwiftUI layer adds "Teach Lyra my voice…" and a meeting window with click-to-rename.

**Tech Stack:** as Phase 1 (Swift 6.4, SwiftPM, SwiftUI/AppKit, FluidAudio 0.17.7 `OfflineDiarizerManager` — `DiarizationResult.speakerDatabase: [String: [Float]]?` gives per-cluster centroids; `TimedSpeakerSegment.embedding` per segment), XCTest. No new dependency.

**Spec:** `docs/superpowers/specs/2026-10-27-lyra-design.md` (§5.3 steps 1 and 4, rename, learning; §4 anti-goals). Phase 1 handoff: `docs/notes/phase1-findings.md`.

## What today's tests showed (2026-10-27, `~/Documents/Lyra Recordings/2026-10-27 0405/0409 — Google Chrome`)

- Solo Meet call → meeting track exactly silent → note carried the "silent / check permission" warning although nothing was wrong.
- Meet + a YouTube video in Chrome (only Aidan and the video present) → call audio captured, echo filter correct, but **Aidan's mic voice was split into two speakers** (Speaker 2: four 1–3-word fragments; Speaker 3: the long stretches); the video was Speaker 1.
- Both notes titled "Google Chrome": window names are unreadable without the Screen Recording permission (System Audio Recording alone doesn't grant `kCGWindowName`).

## Global Constraints

- All Phase 1 global constraints still apply (Apple Silicon, macOS 27.2, `.macOS(.v15)`, bundle `au.aidos.lyra`, no capture before Allow/Start, English only, no new dependency beyond FluidAudio, paths and name format unchanged, `meeting.json` + `transcript.json` are the master copy).
- **Voice fingerprints never leave the Mac.** People DB lives at `~/Library/Application Support/Lyra/people.json`, file mode 0600, never inside the Obsidian vault or the recordings folder.
- **A wrong name is worse than "Speaker N".** Auto-name only when the match clears both the similarity floor and the margin over the runner-up (VoiceMatcher defaults below). Ties or near-ties → "Speaker N".
- **Learning is future-only.** Naming a voice never rewrites other meetings' notes or transcripts.
- **Only confirmed voices are learned:** samples are added on enrolment and on Aidan's renames, never from automatic matches (prevents drift).
- Lyra rewrites only its marked sections (`<!-- lyra:transcript:start/end -->`). If that section was edited in Obsidian since Lyra last wrote it, ask before replacing.
- Old Phase 1 meeting folders (no `speakers.json`, no `speakerID` on lines) must still load, display, and accept renames of whole "Speaker N" labels (without learning, since no centroid exists).

## Review Focus

1. **Two clusters on one track both match the same person** (Aidan's split voice) → one name, consecutive lines merged, never "Aidan" and "Speaker 2" for the same voice. (Task 4)
2. **Two different clusters match the same person in one meeting from different tracks** (Aidan on mic, Aidan's voice leaking into the call track) → both named, echo rule still applies first. (Task 4)
3. **Rename to an existing person's name typed with different case/spacing** ("marco ", "Marco") → same person, not a duplicate. (Task 5)
4. **Note edited inside the transcript section in Obsidian, then rename** → Lyra asks; cancelling leaves the note byte-identical while transcript.json and the people DB still update. (Task 5)
5. **Corrupt or missing people.json** → app still records and transcribes; corrupt file is moved aside (`people.json.corrupt-<timestamp>`), never silently overwritten. (Task 3)

---

### Task 1: Phase 1 fixes from real calls

**Files:**
- Modify: `Sources/LyraSpeech/AudioLoader.swift`, `Sources/LyraCore/Pipeline/MeetingProcessor.swift`, `Sources/LyraCore/Capture/Recording.swift`, `Sources/LyraAudio/TwoTrackRecorder.swift`, `Sources/Lyra/AppModel.swift`
- Test: `Tests/LyraCoreTests/MeetingProcessorTests.swift`, `Tests/LyraIntegrationTests/SpeechTests.swift`

**Interfaces:**
- Produces: `TrackResult.startOffset: Double?` (seconds after the earliest track's first frame; nil in old files); `MeetingProcessor.noSoundWarning(appName: String) -> String`.

- [ ] **Step 1: Failing tests:**
  - `testSilentMeetingTrackWarningIsNeutral` — meeting track peak 0, app "Google Chrome" → warning text exactly: `"No sound came from Google Chrome during this meeting, so the transcript is from your microphone only. If other people spoke, check System Settings → Privacy & Security → Screen & System Audio Recording for Lyra."`
  - `testMicLinesShiftedByStartOffset` — meeting track offset 0, mic track `startOffset 2.5`, fake mic line at 1.0 s → merged line starts at 3.5 s.
  - `testOldTrackWithoutOffsetDecodes` — meeting.json without `startOffset` decodes, offset treated as 0.
  - Integration (gated): `testLoadsAACThroughEnd` — encode the fixture to M4A (AAC) in a temp dir, `load16kMono` returns ≈ 43 s of samples without throwing.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Implement:
  - AudioLoader: treat a read error after audio has already been read as end-of-file (compressed formats overestimate `length`).
  - TwoTrackRecorder records each track's first-frame host time; `stop()` fills `startOffset` relative to the earliest; MeetingProcessor adds it to every line of that track before merging.
  - Replace `silentWarning` with `noSoundWarning(appName:)` (keep the 0.005 threshold).
  - AppModel: on first Allow, call `CGPreflightScreenCaptureAccess()`; if false, `CGRequestScreenCaptureAccess()` once (never block recording on it). Title: front layer-0 window of the meeting app's **owning app pid** (helper → owner, e.g. Chrome), name with a trailing ` - Google Chrome` / ` - Microsoft Edge` / ` – Safari`-style browser suffix stripped; fallback app name.
- [ ] **Step 4:** run → PASS; full `swift test`.
- [ ] **Step 5:** Commit `fix: neutral no-sound warning, track start offsets, AAC loading, meeting titles`.

---

### Task 2: Cluster fingerprints out of diarization

**Files:**
- Modify: `Sources/LyraCore/Transcript/Speech.swift`, `Sources/LyraCore/Transcript/TrackTranscriber.swift`, `Sources/LyraCore/Transcript/TranscriptLine.swift`, `Sources/LyraSpeech/FluidDiarizer.swift`, `Sources/LyraCore/Pipeline/MeetingProcessor.swift`
- Create: `Sources/LyraCore/People/SpeakerCluster.swift`
- Test: `Tests/LyraCoreTests/TrackTranscriberTests.swift`, `Tests/LyraIntegrationTests/SpeechTests.swift`

**Interfaces:**
- Produces:
  - `struct Diarization: Sendable { let turns: [SpeakerTurn]; let centroids: [String: [Float]] }` (raw cluster id → L2-normalised embedding); `protocol SpeakerDiarizing { func diarize(samples: [Float]) async throws -> Diarization }`.
  - `struct SpeakerCluster: Codable, Sendable, Equatable { let id: String /* "track:raw" */; let track: TrackKind; let centroid: [Float]; let speechSeconds: Double }`.
  - `TrackTranscriber.run(...) -> (lines: [TranscriptLine], clusters: [SpeakerCluster])`.
  - `TranscriptLine` gains `speakerID: String?` (the raw `"track:cluster"`, kept after relabelling), `personID: UUID?`, `nameSource: NameSource?`, `confidence: Double?`; `enum NameSource: String, Codable, Sendable { case knownVoice, setByAidan }`. All optional → old files decode.
  - Meeting folder gains `speakers.json` = `[SpeakerCluster]`, written with transcript.json.
- [ ] **Step 1: Failing tests:** `testRunReturnsClusterPerSpeaker` (fake diarizer with 2 centroids → 2 clusters, `speechSeconds` = summed turn time); `testSpeakerIDSurvivesMerge` (after `TranscriptMerger.merge`, `speakerID` still the raw id while `speakerLabel` is "Speaker N"); `testOldTranscriptLineDecodes`; integration `testFixtureClustersHaveCentroids` (each cluster centroid has the engine's dimension and unit length ± 1e-3).
- [ ] **Step 2:** FAIL. **Step 3:** implement — FluidDiarizer reads `speakerDatabase`, falling back to the mean of that speaker's segment `embedding`s, then L2-normalises. **Step 4:** PASS + full suite.
- [ ] **Step 5:** Commit `feat(speech): per-cluster voice fingerprints`.

---

### Task 3: People store and voice matcher

**Files:**
- Create: `Sources/LyraCore/People/Person.swift`, `Sources/LyraCore/People/PeopleStore.swift`, `Sources/LyraCore/People/VoiceMatcher.swift`
- Test: `Tests/LyraCoreTests/PeopleStoreTests.swift`, `Tests/LyraCoreTests/VoiceMatcherTests.swift`

**Interfaces:**
- Produces:
  - `struct Person: Codable, Sendable, Identifiable { let id: UUID; var name: String; var isOwner: Bool; var samples: [[Float]]; var updatedAt: Date; var prototype: [Float] /* computed: L2-normalised mean of samples */ }`.
  - `final class PeopleStore: @unchecked Sendable { init(fileURL: URL); static let defaultURL /* ~/Library/Application Support/Lyra/people.json */; func all() -> [Person]; func person(named: String) -> Person? /* trimmed, case-insensitive */; @discardableResult func learn(name: String, sample: [Float], isOwner: Bool = false) throws -> Person; func rename(_ id: UUID, to: String) throws }` — serialised by a lock; atomic writes; file mode 0600; keeps the newest `maxSamples = 20` per person.
  - `struct MatchPolicy: Sendable { var minSimilarity: Double = 0.60; var minMargin: Double = 0.10 }`; `struct VoiceMatch: Sendable, Equatable { let personID: UUID; let similarity: Double }`; `enum VoiceMatcher { static func match(_ centroid: [Float], people: [Person], policy: MatchPolicy = .init()) -> VoiceMatch? }` — cosine similarity against each prototype; returns best only if `≥ minSimilarity` and `best − secondBest ≥ minMargin`.
- [ ] **Step 1: Failing tests:** `testLearnCreatesThenAppends`; `testNameLookupIgnoresCaseAndSpaces` *(Review Focus 3)*; `testSamplesCappedAt20`; `testCorruptFileMovedAsideNotOverwritten` *(Review Focus 5)*; `testFileIsOwnerOnly` (0600); `testMatchAboveFloorAndMargin`; `testNoMatchBelowFloor`; `testNoMatchWhenTwoPeopleTooClose`; `testNoPeopleNoMatch`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS + full suite.
- [ ] **Step 5:** Commit `feat(people): local people store and voice matcher`.

---

### Task 4: Naming speakers in the pipeline

**Files:**
- Create: `Sources/LyraCore/People/SpeakerNamer.swift`
- Modify: `Sources/LyraCore/Transcript/TranscriptMerger.swift`, `Sources/LyraCore/Pipeline/MeetingProcessor.swift`, `Sources/LyraCore/Output/NoteRenderer.swift`, `Sources/Lyra/AppModel.swift`
- Test: `Tests/LyraCoreTests/SpeakerNamerTests.swift`, `Tests/LyraCoreTests/NoteRendererTests.swift`, `Tests/LyraIntegrationTests/PeopleIntegrationTests.swift`

**Interfaces:**
- Consumes: `SpeakerCluster`, `PeopleStore.all()`, `VoiceMatcher.match`.
- Produces: `enum SpeakerNamer { static func name(lines: [TranscriptLine], clusters: [SpeakerCluster], people: [Person], policy: MatchPolicy) -> [TranscriptLine] }` — runs after the echo filter; matched clusters get the person's name, `personID`, `nameSource = .knownVoice`, `confidence = similarity`; unmatched clusters are numbered "Speaker 1…" by first appearance (numbering skips named people); consecutive lines of the same person on the same track within `TrackTranscriber.maxPause` are joined. `MeetingProcessor` gains `people: @Sendable () -> [Person]` injection.
- Note line format: named by voice → `**Marco** _(known voice)_ [00:12:04] …`; set by Aidan → `**Marco** [00:12:04] …`; unknown → `**Speaker 2** [00:12:04] …`.
- [ ] **Step 1: Failing tests:** `testTwoClustersSamePersonOneName` *(Review Focus 1)*; `testSamePersonAcrossTracks` *(Review Focus 2)*; `testUnknownsNumberedSkippingNamed`; `testLowConfidenceStaysSpeakerN`; `testRenderKnownVoiceBadge`. Integration (gated): enrol "Daniel" from a fresh `say -v Daniel` clip (different sentences from the fixture), process the fixture → every line Daniel actually spoke is named Daniel, no other voice is named Daniel; record similarities for all three voices in `docs/notes/phase2-findings.md`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS + full suite.
- [ ] **Step 5: Calibration (record, don't guess):** re-run the matcher on Aidan's two test meetings (after Task 5 enrolment exists, or by enrolling from the 0409 mic track's longest cluster) and the fixture; record same-voice vs different-voice similarity ranges in `phase2-findings.md`. Change `MatchPolicy` defaults only if the measured gap demands it, and say why.
- [ ] **Step 6:** Commit `feat(people): name known voices in transcripts`.

---

### Task 5: Rename and learn

**Files:**
- Create: `Sources/LyraCore/People/RenameService.swift`, `Sources/LyraCore/Output/NoteSections.swift`
- Modify: `Sources/LyraCore/Model/Meeting.swift` (add `transcriptSectionHash: String?`), `Sources/LyraCore/Pipeline/MeetingProcessor.swift` (store the hash when writing)
- Test: `Tests/LyraCoreTests/RenameServiceTests.swift`, `Tests/LyraCoreTests/NoteSectionsTests.swift`

**Interfaces:**
- Produces:
  - `enum NoteSections { static func replaceTranscript(in note: String, with body: String) throws -> String; static func transcriptBody(of note: String) -> String?; static func hash(_ body: String) -> String /* SHA-256 hex */ }`.
  - `enum RenameOutcome: Equatable { case done; case needsConfirmation /* section edited in Obsidian */ }`.
  - `struct RenameService { init(people: PeopleStore); func rename(speakerLabel: String, to name: String, inMeetingFolder: URL, note: URL, overwriteEditedNote: Bool = false) throws -> RenameOutcome }` — updates every line with that label in transcript.json (`nameSource = .setByAidan`, `personID`), learns each underlying cluster's centroid from speakers.json into the person (`isOwner` untouched), re-renders the transcript section, and writes the note only if the section's current hash equals `meeting.transcriptSectionHash` or `overwriteEditedNote` is true. transcript.json and people.json update regardless.
- [ ] **Step 1: Failing tests:** `testRenameUpdatesAllLinesOfThatSpeaker`; `testRenameLearnsCentroids`; `testRenameExistingPersonDifferentCase` *(Review Focus 3)*; `testEditedSectionNeedsConfirmation` (note bytes unchanged, transcript.json updated) *(Review Focus 4)*; `testOverwriteWhenConfirmed`; `testOtherMeetingsUntouched`; `testPhase1FolderRenamesWithoutLearning` (no speakers.json → names applied, people.json unchanged); `testReplaceTranscriptKeepsOutsideEdits`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS + full suite.
- [ ] **Step 5:** Commit `feat(people): rename speakers and learn their voices`.

---

### Task 6: Teach Lyra my voice + meeting window

**Files:**
- Create: `Sources/Lyra/EnrolmentWindow.swift`, `Sources/Lyra/MeetingWindow.swift`, `Sources/LyraCore/People/Enrolment.swift`
- Modify: `Sources/Lyra/MenuContent.swift`, `Sources/Lyra/AppModel.swift`
- Test: `Tests/LyraCoreTests/EnrolmentTests.swift`

**Interfaces:**
- Consumes: `MicRecorder`, `AudioLoader`, `FluidDiarizer`, `PeopleStore`, `RenameService`, `MeetingProcessor.pendingFolders`/`Meeting.load`.
- Produces:
  - `enum Enrolment { static func ownerSample(from diarization: Diarization) -> [Float]? }` — centroid of the cluster with the most speech; nil if < 8 s of speech.
  - Menu: "Teach Lyra my voice…" (always), "Open last meeting" (replaces "Open last note"; the window has an "Open note in Obsidian" button).
  - EnrolmentWindow: shows a short paragraph to read aloud, records 20 s of mic (only after the user presses Start — consent), runs the diarizer, saves `learn(name: "Aidan", sample:, isOwner: true)`; if < 8 s of speech, says so and offers to retry. Re-running adds a sample.
  - MeetingWindow (one meeting): speakers list (name or "Speaker N", source badge, seconds spoken) and the transcript. Clicking a speaker → field with autocomplete from people → Rename. On `.needsConfirmation` show "This note's transcript was edited in Obsidian. Replace it with the renamed transcript?" (Replace / Keep my edits).
- [ ] **Step 1: Failing tests:** `testOwnerSampleFromLongestCluster`; `testTooLittleSpeechReturnsNil`.
- [ ] **Step 2:** FAIL. **Step 3:** implement the core, then the two windows. **Step 4:** PASS + full suite; `scripts/build-app.sh` exit 0.
- [ ] **Step 5 (👤 Aidan, ~10 min, acceptance):**
  1. Menu → Teach Lyra my voice… → read the paragraph → "Saved".
  2. Repeat today's Meet + YouTube test → note shows **Aidan** _(known voice)_ for all your lines (no split) and the video as Speaker 1; the title is the Meet tab's name, not "Google Chrome" (grant Screen Recording when asked).
  3. Solo Meet call → the note's warning reads "No sound came from Google Chrome…".
  4. Open last meeting → rename Speaker 1 to a test name → note updates; edit the transcript in Obsidian, rename again → Lyra asks before replacing.
  5. Next call with the same video → that name appears as _(known voice)_.
- [ ] **Step 6:** Commit `feat(app): voice enrolment and meeting window with rename`.

## Done when

- `swift test` and `LYRA_INTEGRATION=1 swift test` pass; `scripts/build-app.sh` exits 0.
- Aidan's acceptance run (Task 6 Step 5) passes all five checks.
- `docs/notes/phase2-findings.md` records measured similarity ranges and the final `MatchPolicy`.
