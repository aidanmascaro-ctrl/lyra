# Lyra Phase 1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu-bar-only Mac app that detects a meeting in any app, records only after Allow, captures meeting audio and microphone as two tracks, and after the meeting writes an Obsidian note with a full speaker-separated transcript ("Speaker 1", "Speaker 2"…).

**Architecture:** One SwiftPM package. `LyraCore` holds all pure logic behind small protocols and is fully unit-tested with `swift test`. `LyraAudio` (Core Audio / AVFoundation) and `LyraSpeech` (FluidAudio) are thin adapters implementing those protocols. `Lyra` is the SwiftUI menu-bar app that wires them together. A script assembles and signs a real `.app` bundle.

**Tech Stack:** Swift 6.4, Xcode 27.1, SwiftUI `MenuBarExtra`, AppKit `NSPanel`, Core Audio process taps + process-object mic attribution, AVAudioEngine, FluidAudio (Parakeet ASR + `OfflineDiarizerManager`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-27-lyra-design.md`

## Roadmap (one plan per phase; each phase ships a usable app)

| Phase | Delivers | Spec sections |
|---|---|---|
| **1 Foundation (this plan)** | detection + Allow, two-track capture, offline transcript with Speaker N, echo de-dupe, Obsidian note + recordings folder, crash-safe | 5.1, 5.2, 5.7, 6 |
| 2 People | people DB, voice fingerprints, known-voice matching with confidence, Aidan enrolment, click-to-rename, future-only learning | 5.3 (1, 4), rename |
| 3 Notes | notes window (B) with live transcript, Claude woven expansion (A) via `claude -p`, marked-section rewrites, client picker | 5.4, 5.5, 6 Claude |
| 4 Screen | active-speaker tile reading, slide capture + dedupe + OCR, slides inline in notes | 5.3 (2), 5.6 |
| 5 Polish | conversation name clues, ignore-list "always", start at login, re-run expansion | 5.3 (3), 6 calls |

## Global Constraints

- Target: Apple Silicon, macOS 27.2 (package floor `.macOS(.v15)`); no Intel, no older macOS.
- Bundle ID `au.aidos.lyra`; `LSUIElement = true` (no Dock icon).
- Never start audio or screen capture before the user clicks Allow (or Start in the menu).
- Nothing leaves the Mac in Phase 1 (no network except first-run model download by FluidAudio).
- English only.
- Recordings root: `~/Documents/Lyra Recordings/`. Notes: `~/Documents/Obsidian Vault/Aidan Business/Meetings/`.
- Folder + note name: `YYYY-MM-DD HHmm — <title>` (em dash, spaces around it).
- The meeting's `meeting.json` + `transcript.json` in its recordings folder are the master copy; the note is generated from them.
- Do not assume the mic track is only Aidan: it is diarized like the meeting track.
- No new dependency beyond FluidAudio.

## Review Focus

1. **Meeting app quits or crashes mid-call** → recording stops by itself, files on disk stay playable, transcript + note still produced. (Task 4, Task 7)
2. **Mac sleeps / lid closes mid-call** → capture stops cleanly, partial audio is kept and processed. (Task 7)
3. **Meeting-audio track is silent** (permission denied, tap failed) → note is still written from the mic track with a visible warning line, no crash. (Task 6)
4. **Lyra's own mic use or a second app grabbing the mic while recording** → no new prompt, no detection loop. (Task 2)
5. **Odd titles** (`/`, `:`, emoji, 200 chars) **or two meetings in the same minute** → safe name, never overwrites an existing note or folder. (Task 3)

---

### Task 1: Package skeleton, app bundle, signing

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/LyraCore/LyraCore.swift`, `Sources/LyraAudio/LyraAudio.swift`, `Sources/LyraSpeech/LyraSpeech.swift`, `Sources/Lyra/LyraApp.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `Tests/LyraCoreTests/SmokeTests.swift`, `Tests/Fixtures/speaker-test-3-voices.wav` (copy from `~/Desktop/speaker-test-3-voices.wav`)

**Interfaces:**
- Produces: targets `LyraCore` (no deps), `LyraAudio` (→ LyraCore), `LyraSpeech` (→ LyraCore, FluidAudio `from: "0.17.7"`), executable `Lyra` (→ all three); test targets `LyraCoreTests`, `LyraIntegrationTests` (→ LyraAudio, LyraSpeech; fixtures as resources). `LyraCore.version: String = "0.1.0"`.

- [ ] **Step 1:** `git init` in `~/Documents/lyra`; commit the existing `docs/` first (`docs: add Lyra design and phase 1 plan`).
- [ ] **Step 2: Failing test** — `SmokeTests.testVersion`: `XCTAssertEqual(LyraCore.version, "0.1.0")`.
- [ ] **Step 3:** Run `swift test --filter SmokeTests` → FAIL (no package).
- [ ] **Step 4:** Write `Package.swift` and the empty target files; `LyraApp.swift` is a `@main` SwiftUI `App` with a `MenuBarExtra("Lyra", systemImage: "waveform")` containing a Quit button.
- [ ] **Step 5:** Run `swift test --filter SmokeTests` → PASS.
- [ ] **Step 6:** `Resources/Info.plist`: `CFBundleIdentifier au.aidos.lyra`, `CFBundleName Lyra`, `CFBundleExecutable Lyra`, `LSUIElement true`, `LSMinimumSystemVersion 15.0`, `NSMicrophoneUsageDescription` = "Lyra records your microphone during meetings you allow.", `NSAudioCaptureUsageDescription` = "Lyra records the meeting app's audio during meetings you allow."
- [ ] **Step 7:** `scripts/build-app.sh`: `swift build -c release`, assemble `build/Lyra.app/Contents/{MacOS,Resources,Info.plist}`, then `codesign --force --deep -s "${LYRA_SIGN_ID:-Lyra Local}" build/Lyra.app`, falling back to ad-hoc `-s -` with a printed warning if that identity is missing. Exits non-zero on any failure.
- [ ] **Step 8:** Run `scripts/build-app.sh && codesign -v build/Lyra.app && open build/Lyra.app` → waveform icon appears in the menu bar, no Dock icon.
- [ ] **Step 9 (👤 Aidan, one-off, ~2 min):** Keychain Access → Certificate Assistant → Create a Certificate… Name `Lyra Local`, Identity Type *Self Signed Root*, Certificate Type *Code Signing*. Re-run Step 8; script must no longer print the ad-hoc warning. This keeps macOS permissions across rebuilds.
- [ ] **Step 10:** Commit `chore: package skeleton, app bundle and signing script`.

---

### Task 2: Meeting detection

**Files:**
- Create: `Sources/LyraCore/Detection/MicUser.swift`, `Sources/LyraCore/Detection/MeetingDetector.swift`, `Sources/LyraAudio/CoreAudioMicUsage.swift`
- Test: `Tests/LyraCoreTests/MeetingDetectorTests.swift`

**Interfaces:**
- Produces:
  - `struct MicUser: Hashable, Sendable { let pid: pid_t; let bundleID: String; let appName: String }`
  - `protocol MicUsageProvider: Sendable { func currentMicUsers() -> [MicUser] }`
  - `enum DetectorEvent: Equatable { case meetingStarted(MicUser); case meetingEnded(MicUser) }`
  - `final class MeetingDetector { init(ownPID: pid_t, ignoredBundleIDs: Set<String>, endGrace: TimeInterval = 10); func update(users: [MicUser], now: Date) -> [DetectorEvent]; var isRecording: Bool { get set } }`
  - `final class CoreAudioMicUsage: MicUsageProvider` — lists Core Audio process objects (`kAudioHardwarePropertyProcessObjectList`) where `kAudioProcessPropertyIsRunningInput` is true; reads `kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID`; app name from `NSRunningApplication` (for helper processes, walk up to the owning app, e.g. `com.google.Chrome.helper` → Google Chrome).

Rules `update` must follow: excludes `ownPID` and ignored bundle IDs; emits `meetingStarted` once when a new app starts using the mic **and `isRecording` is false**; while recording, other apps grabbing the mic emit nothing; emits `meetingEnded` for the app being recorded only after it has been absent for `endGrace` seconds continuously.

- [ ] **Step 1: Failing tests** in `MeetingDetectorTests`:
  - `testStartsOnceForNewMicUser` — zoom appears in 3 consecutive updates → exactly one `.meetingStarted(zoom)`.
  - `testIgnoresOwnProcess` — user with `pid == ownPID` → `[]`. *(Review Focus 4)*
  - `testIgnoresSecondAppWhileRecording` — `isRecording = true` for zoom; chrome appears → `[]`. *(Review Focus 4)*
  - `testEndsAfterGrace` — zoom absent at t+5 → `[]`; still absent at t+11 → `[.meetingEnded(zoom)]`.
  - `testBriefDropDoesNotEnd` — absent t+5, back t+6, absent t+12 → no end yet at t+12.
  - `testIgnoredBundle` — `ignoredBundleIDs = ["com.apple.VoiceMemos"]` → `[]`.
- [ ] **Step 2:** `swift test --filter MeetingDetectorTests` → FAIL.
- [ ] **Step 3:** Implement `MicUser`, `MeetingDetector`.
- [ ] **Step 4:** `swift test --filter MeetingDetectorTests` → PASS.
- [ ] **Step 5:** Implement `CoreAudioMicUsage`. Integration test `LyraIntegrationTests/MicUsageTests.testSeesOwnEngine` (gated by `LYRA_INTEGRATION=1`): start an `AVAudioEngine` input tap, assert `currentMicUsers()` contains this test process's PID.
- [ ] **Step 6:** `LYRA_INTEGRATION=1 swift test --filter MicUsageTests` → PASS (grant mic permission to Terminal if asked).
- [ ] **Step 7:** Commit `feat(detection): detect meetings from mic usage`.

---

### Task 3: Meeting model and paths

**Files:**
- Create: `Sources/LyraCore/Model/Meeting.swift`, `Sources/LyraCore/Output/MeetingPaths.swift`
- Test: `Tests/LyraCoreTests/MeetingPathsTests.swift`

**Interfaces:**
- Produces:
  - `enum TrackKind: String, Codable, Sendable { case meeting, mic }`
  - `struct Meeting: Codable, Sendable { let id: UUID; var title: String; let appName: String; let bundleID: String?; let startedAt: Date; var endedAt: Date?; var warnings: [String] }`
  - `struct MeetingPaths { init(recordingsRoot: URL, notesDir: URL, fileManager: FileManager = .default); func folderName(title: String, startedAt: Date, timeZone: TimeZone) -> String; func reserve(for meeting: Meeting, timeZone: TimeZone) throws -> (folder: URL, note: URL) }` — `reserve` creates the recordings folder and returns a note URL that does not yet exist.
  - Files in a meeting folder: `meeting.json`, `transcript.json`, `meeting.caf`, `mic.caf` (later `meeting.m4a`, `mic.m4a`).
  - Defaults: `MeetingPaths.defaultRecordingsRoot = ~/Documents/Lyra Recordings`, `MeetingPaths.defaultNotesDir = …/Aidan Business/Meetings`.

- [ ] **Step 1: Failing tests:**
  - `testFolderName` — title "Elm Park Workshop 2", 2026-11-01 17:00 Perth → `"2026-11-01 1700 — Elm Park Workshop 2"`.
  - `testSanitisesTitle` — title `"Q3: plan/review 🚀"` → no `/` or `:` in result; emoji kept; result ≤ 120 chars for a 200-char title. *(Review Focus 5)*
  - `testEmptyTitleFallsBackToAppName` — empty title, appName "Zoom" → ends with `"— Zoom"`.
  - `testReserveNeverOverwrites` — reserve twice for same minute/title in a temp dir → second folder and note end in `" (2)"`; first untouched. *(Review Focus 5)*
- [ ] **Step 2:** `swift test --filter MeetingPathsTests` → FAIL.
- [ ] **Step 3:** Implement. Replace `/ : \ ? * " < > |` and newlines with `-`, collapse spaces, trim, truncate to 120.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat(core): meeting model and safe paths`.

---

### Task 4: Two-track recording

**Files:**
- Create: `Sources/LyraCore/Capture/Recording.swift`, `Sources/LyraAudio/MicRecorder.swift`, `Sources/LyraAudio/AppAudioRecorder.swift`, `Sources/LyraAudio/TwoTrackRecorder.swift`
- Test: `Tests/LyraIntegrationTests/RecorderTests.swift`

**Interfaces:**
- Consumes: `MicUser`, `TrackKind`.
- Produces:
  - `protocol TrackRecorder: AnyObject { func start(writingTo url: URL) throws; func stop() async -> TrackResult }`
  - `struct TrackResult: Sendable { let kind: TrackKind; let url: URL; let seconds: Double; let peakLevel: Float; let error: String? }`
  - `final class MicRecorder: TrackRecorder` — AVAudioEngine input → CAF (native format).
  - `final class AppAudioRecorder: TrackRecorder` — `init(target: MicUser)`. Core Audio process tap (`CATapDescription(stereoMixdownOfProcesses:)`) over every process object whose bundle ID equals the target's or has it as a prefix (catches Chrome/Zoom helpers); `muteBehavior = .unmuted`; private aggregate device; IO proc writes CAF.
  - `final class TwoTrackRecorder { init(target: MicUser?); func start(in folder: URL) throws; func stop() async -> [TrackResult] }` — `target == nil` (in-person) records mic only.
  - CAF is used during capture because a partially written CAF stays playable after a crash. *(Review Focus 1)*

- [ ] **Step 1: Failing test** (`LYRA_INTEGRATION=1`): `testAppAudioCapturesAfplay` — launch `/usr/bin/afplay Tests/Fixtures/speaker-test-3-voices.wav`, record it with `AppAudioRecorder(target: afplay)` for 5 s → `seconds ≥ 4`, `peakLevel > 0.01`, `error == nil`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement the three recorders.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5: Muted check (spec risk 1)** — same test with output volume muted first (`osascript -e 'set volume output muted true'`, restore after): `testAppAudioCapturesWhileMuted` → `peakLevel > 0.01`. If it fails, record the finding in `docs/notes/phase1-findings.md` and switch `muteBehavior` / tap options until it passes; do not proceed with a failing mute test.
- [ ] **Step 6:** `testCrashLeavesPlayableFile` — start mic recording, write 2 s, abandon without `stop()`; `AVAudioFile(forReading:)` opens it and `length > 0`. *(Review Focus 1)*
- [ ] **Step 7:** Commit `feat(audio): two-track capture via process tap and mic`.

---

### Task 5: Speech pipeline (diarize → transcribe)

**Files:**
- Create: `Sources/LyraCore/Transcript/TranscriptLine.swift`, `Sources/LyraCore/Transcript/Speech.swift`, `Sources/LyraCore/Transcript/TrackTranscriber.swift`, `Sources/LyraSpeech/FluidDiarizer.swift`, `Sources/LyraSpeech/FluidTranscriber.swift`, `Sources/LyraSpeech/AudioLoader.swift`
- Test: `Tests/LyraCoreTests/TrackTranscriberTests.swift`, `Tests/LyraIntegrationTests/SpeechTests.swift`

**Interfaces:**
- Produces:
  - `struct SpeakerTurn: Sendable { let speaker: String; let start: Double; let end: Double }` (speaker = engine's raw cluster id)
  - `struct TranscriptLine: Codable, Equatable, Sendable { var speakerLabel: String; let track: TrackKind; let start: Double; let end: Double; let text: String }`
  - `protocol SpeakerDiarizing: Sendable { func diarize(samples: [Float]) async throws -> [SpeakerTurn] }`
  - `protocol SpeechTranscribing: Sendable { func transcribe(samples: [Float]) async throws -> String }`
  - `struct TrackTranscriber { init(diarizer: SpeakerDiarizing, transcriber: SpeechTranscribing); func run(samples: [Float], track: TrackKind, sampleRate: Double = 16_000) async throws -> [TranscriptLine] }` — returns lines with `speakerLabel` = raw id prefixed by track (`"meeting:0"`, `"mic:1"`); merges consecutive turns of the same speaker shorter than 0.5 s apart; skips turns < 0.3 s.
  - `AudioLoader.load16kMono(url: URL) throws -> [Float]`
  - `FluidDiarizer: SpeakerDiarizing` wraps `OfflineDiarizerManager` (`prepareModels()`, `process(audio:)`); `FluidTranscriber: SpeechTranscribing` wraps `AsrManager` with `AsrModels.downloadAndLoad(version: .v3)` (English). Read FluidAudio's source for exact result field names; keep all FluidAudio types inside `LyraSpeech`.

- [ ] **Step 1: Failing unit tests** (fakes for both protocols):
  - `testOneLinePerTurn` — turns `[A 0–2, B 2–4, A 4–6]` → 3 lines, labels `meeting:A, meeting:B, meeting:A`, text from fake.
  - `testMergesSameSpeakerTurns` — `[A 0–2, A 2.2–4]` → 1 line `0–4`.
  - `testSkipsBlips` — `[A 0–0.2]` → `[]`.
  - `testSliceUsesSampleRate` — fake transcriber records slice length; turn 1–2 s at 16 kHz → 16 000 samples.
- [ ] **Step 2:** `swift test --filter TrackTranscriberTests` → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [ ] **Step 5: Integration** (`LYRA_INTEGRATION=1`, first run downloads models): `SpeechTests.testThreeVoiceFixture` — run real adapters on the fixture → distinct speaker labels ≥ 2 (target 3), joined text contains "Friday" and "gear list". Record actual speaker count in `docs/notes/phase1-findings.md`.
- [ ] **Step 6:** Run → PASS.
- [ ] **Step 7:** Commit `feat(speech): on-device diarization and transcription`.

---

### Task 6: Merge, echo de-dupe, labels, note

**Files:**
- Create: `Sources/LyraCore/Transcript/TranscriptMerger.swift`, `Sources/LyraCore/Output/NoteRenderer.swift`
- Test: `Tests/LyraCoreTests/TranscriptMergerTests.swift`, `Tests/LyraCoreTests/NoteRendererTests.swift`

**Interfaces:**
- Consumes: `TranscriptLine`, `Meeting`.
- Produces:
  - `enum TranscriptMerger { static func merge(meeting: [TranscriptLine], mic: [TranscriptLine]) -> [TranscriptLine] }` — drops a mic line when a meeting line overlaps it in time (±2 s) and their word-set Jaccard similarity ≥ 0.6 (echo of the call through speakers); sorts by `start`; relabels raw ids to `"Speaker 1"`, `"Speaker 2"`… in order of first appearance across both tracks (meeting and mic clusters never share a number).
  - `enum NoteRenderer { static func render(meeting: Meeting, lines: [TranscriptLine], recordingsFolder: URL) -> String }`

Note format (exact):

```markdown
---
lyra_id: <uuid>
date: 2026-11-01T17:00:00+08:00
app: Zoom
duration_min: 52
recordings: "file://~/Documents/Lyra%20Recordings/…"
tags: [meeting]
---
# <title>

> [!warning] <one callout per warning>

## Notes
<!-- lyra:notes:start -->
<!-- lyra:notes:end -->

## Transcript
<!-- lyra:transcript:start -->
**Speaker 1** [00:00:04] text…
<!-- lyra:transcript:end -->
```

- [ ] **Step 1: Failing tests:**
  - `testDropsEcho` — meeting "we move it to friday afternoon" 10–13 s; mic "move it to friday afternoon" 10.5–13 s → mic line gone.
  - `testKeepsRealMicSpeech` — mic "sounds good to me" 20–21 s, no overlap → kept.
  - `testLabelsInOrderOfAppearance` — first `mic:0`, then `meeting:3`, then `mic:0` → `Speaker 1, Speaker 2, Speaker 1`.
  - `testRenderHasMarkersAndTimestamps` — rendered note contains both marker pairs and `"**Speaker 1** [00:00:04]"`.
  - `testSilentMeetingTrackWarning` — meeting with `warnings = ["Meeting audio was silent — transcript is from your microphone only."]` → note contains `> [!warning] Meeting audio was silent`. *(Review Focus 3)*
- [ ] **Step 2:** → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat(core): merge tracks, drop echoes, render note`.

---

### Task 7: App wiring — prompt, record, process, save

**Files:**
- Create: `Sources/Lyra/AppModel.swift`, `Sources/Lyra/AllowPanel.swift`, `Sources/Lyra/MenuContent.swift`, `Sources/Lyra/MeetingSession.swift`, `Sources/LyraCore/Pipeline/MeetingProcessor.swift`
- Modify: `Sources/Lyra/LyraApp.swift`
- Test: `Tests/LyraCoreTests/MeetingProcessorTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `struct MeetingProcessor { init(trackTranscriber: TrackTranscriber, loader: @Sendable (URL) throws -> [Float]); func process(meeting: Meeting, tracks: [TrackResult], folder: URL, noteURL: URL) async throws -> URL }` — transcribes each track, adds the silent-track warning when the meeting track's `peakLevel < 0.005` or it has an `error`, merges, writes `transcript.json` + `meeting.json`, converts CAF → M4A (AAC) and deletes the CAF only after the M4A verifies, writes the note atomically; returns note URL.
  - `AppModel` (`@MainActor`, `ObservableObject`): polls `CoreAudioMicUsage` every 1 s into `MeetingDetector`; on `.meetingStarted` shows `AllowPanel`; on Allow builds a `MeetingSession`; on `.meetingEnded`, Stop, quit, or `NSWorkspace.willSleepNotification` stops and processes. *(Review Focus 1, 2)*
  - Meeting title: the meeting app's front window title via `CGWindowListCopyWindowInfo` (`kCGWindowName`, available once Screen Recording is granted); falls back to the app name. Editing titles comes in Phase 3.
  - `AllowPanel`: non-activating `NSPanel` under the menu bar icon, top-right; shows "● <App> meeting detected" and window/tab title; buttons **Allow**, **Ignore** (the slides button arrives in Phase 4); auto-dismisses as Ignore after 60 s.
  - Menu: idle → "Start recording (in person)", "Quit"; recording → red dot + elapsed `mm:ss` in the menu bar title, "Stop recording"; processing → "Processing…"; done → "Open last note".
  - On launch, any meeting folder with `.caf` files but no `transcript.json` is processed (recovers after a crash). *(Review Focus 1)*

- [ ] **Step 1: Failing tests** for `MeetingProcessor` with fake diarizer/transcriber and a temp folder:
  - `testWritesNoteAndMaster` — two tracks → note exists at `noteURL`, `transcript.json` decodes to the merged lines.
  - `testSilentMeetingTrackStillWritesNote` — meeting `TrackResult(peakLevel: 0)` → note written, contains the warning. *(Review Focus 3)*
  - `testMicOnlyMeeting` — tracks `[mic]` only → note written, no warning.
- [ ] **Step 2:** → FAIL. **Step 3:** implement processor, then the app pieces. **Step 4:** → PASS.
- [ ] **Step 5:** `swift build && scripts/build-app.sh` → exit 0.
- [ ] **Step 6 (👤 Aidan, ~10 min, acceptance):** open `build/Lyra.app`; grant Microphone + Screen & System Audio Recording when asked. Then:
  1. Join any Zoom/Meet/Teams/FaceTime call → prompt appears within ~2 s; nothing records until Allow.
  2. Allow; talk with one other person; **mute the Mac's volume halfway through**.
  3. Leave the call → within ~10 s the menu shows Processing…, then "Open last note".
  4. Note in `Aidan Business/Meetings/` has both speakers as Speaker 1/2, the muted half is still transcribed, no doubled lines; `~/Documents/Lyra Recordings/<same name>/` has `meeting.m4a`, `mic.m4a`, `meeting.json`, `transcript.json`.
  5. Force-quit Lyra mid-call, relaunch → that meeting is processed and its note appears.
- [ ] **Step 7:** Commit `feat(app): menu bar flow from detection to Obsidian note`.

---

## Done when

- `swift test` passes; `LYRA_INTEGRATION=1 swift test` passes on Aidan's Mac.
- `scripts/build-app.sh` exits 0 and the signed app survives a rebuild without re-asking for permissions.
- Aidan's acceptance run (Task 7 Step 6) passes all five checks.
