# Lyra — design

*Date: 2026-10-27. Owner: Aidan Mascaro (no coding background; Claude Code builds and maintains it).*
*Sister app to Leo. Name from the constellation of the lyre — the one that listens.*

## 1. What it is and why

Lyra is a personal macOS meeting recorder that lives only in the menu bar. When a meeting starts it
asks permission, then records, transcribes with **named speakers**, captures slides, and lets Aidan
take notes that Claude later expands from the transcript.

**Why it exists.** Aidan tried Granola, Anarlog (ex-Hyprnote) and Meetily (Oct 2026):

- Granola: loved writing notes inside it and having the transcript expand them. But the raw
  transcript is paywalled, and desktop transcripts only split "me" vs "everyone else".
- Anarlog / Meetily: speech recognition was fine, but neither had the note-taking flow he wants.

What he values most, in order:

1. **The raw, full transcript with speaker detection** — kept forever, as fuel for a personal
   knowledge base ("a brain"). Speaker detection is the single most important feature.
2. Granola-style notes: he types during the meeting, the transcript expands them afterwards.
3. Slide screenshots, as a backup for when the presenter never sends the deck or notes.

**Success looks like:** after a call, one Obsidian note holds his notes woven with Claude's additions,
the full transcript with real names on most lines, and the slides — without him touching anything
except "Allow" and maybe renaming a speaker or two. Over months, regulars get named automatically.

## 2. Goals

- Menu-bar only. No Dock icon. Elegant and sleek; invisible until needed.
- Auto-detect a meeting in **any** app (Zoom, Google Meet in a browser, Teams, FaceTime, anything);
  **never record until Aidan clicks Allow**.
- Capture the meeting's audio **directly from the app**, not through speakers — must work with
  headphones, speakers turned down, or muted. No BlackHole or audio routing setup.
- Full transcript with speaker separation and names, learning voices over time.
- Notes window during the meeting; Claude expands notes afterwards.
- Slide/scene screenshots saved with the meeting.
- Everything saved to Aidan's Obsidian vault + a recordings folder on his Mac.

## 3. Non-goals

- No full video recording (screenshots replace it; add an optional video setting only if asked later).
- No calendar integration, no joining-bot, no cloud sync, no sharing, no team features.
- No mobile app.
- Not a Leo feature — separate app, separate folder. (Leo may read its output later; not now.)
- No multi-tenant / SaaS considerations. Personal tool.

## 4. Anti-goals (would be a failure even if it technically works)

- **Recording without consent.** Lyra must never start capturing audio or screen without the Allow
  click. (WA law generally requires all parties' consent to record a private conversation; Aidan is
  responsible for announcing it, Lyra is responsible for never recording silently.)
- **Confidently wrong names.** A wrong name in the knowledge base is worse than "Speaker 2". Only
  auto-fill a name when confident.
- **Audio, voiceprints or transcripts leaving the Mac**, other than the text sent to Claude for the
  note expansion. Voice fingerprints are sensitive personal data and stay local only.
- **Losing a meeting.** A crash, sleep, or quit mid-meeting must not lose what was already captured.
- Being noisy: no popups for things that aren't meetings (e.g. a voice memo, dictation) that
  Aidan has already ignored for that app.

## 5. How it works — decided with Aidan

### 5.1 Meeting detection and consent
- Trigger: any app starts using the microphone. Prompt drops from the menu bar icon showing the app
  name (and browser tab title for web meetings, e.g. "Chrome — Google Meet").
- Prompt buttons: **Allow**, **Allow + capture slides**, **Ignore**.
- In-person meetings: Aidan starts recording manually from the menu bar (microphone only).
- Recording state is always visible in the menu bar (e.g. red dot + elapsed time).

### 5.2 Audio
- Two separate tracks, both kept:
  - **Meeting audio** (primary, clearest): captured directly from the meeting app's output.
  - **Microphone** (secondary): Aidan's voice; in person, the whole room.
- The mic track is **not** assumed to be only Aidan: he is sometimes on a call with other people in
  the room (hybrid meetings). The mic track is diarized on its own, and Aidan is recognised by his own
  voice fingerprint like anyone else (he is enrolled as a known person, e.g. from his first meetings).
- When Aidan is on speakers, the mic also hears the call — those echoes are dropped using the meeting
  track as reference, so no line appears twice.
- Must verify early that capture works with system volume **fully muted**, not just low.

### 5.3 Speaker identification (most important feature)
Every voice gets a **voice fingerprint** (speaker embedding). Names are found in this order:

1. **Known people** — match against fingerprints saved in Lyra's people database. Confident match → name.
2. **On-screen** (calls only) — watch the meeting window for the lit-up active-speaker border and
   read the name under that tile. Voice active while tile lit → that name.
3. **Conversation clues** — people addressing each other ("Thanks, Tomas", "Marco, what do you
   think?") as evidence for who speaks next.
4. **Fallback** — anyone still unknown at the end is "Speaker 1", "Speaker 2"…

- Each name carries a confidence and its source (known voice / on screen / named in conversation /
  set by Aidan), shown in the transcript.
- Only confident names are filled in automatically.
- **Renaming:** click "Speaker 3" → type a name (or pick an existing person). Renames every line from
  that speaker in that meeting and saves/merges the voice into that person's profile.
- **Learning:** every person has a permanent ID; their fingerprint is refined from each meeting they're
  confirmed in. Aidan himself is a person too.
- **Learning applies to future meetings only.** Naming a voice never rewrites past meetings' notes
  (decided by Aidan). Old notes keep "Speaker 2" unless Aidan renames them in that meeting.
- In-person meetings rely on fingerprints + conversation clues only, so expect more manual renaming.

### 5.4 The notes window (during the meeting) — mockup option B
- Opens when recording starts. Left: Aidan's notes (plain typing, bullet-friendly). Right: live
  transcript scrolling, names filling in as they're worked out.
- Closing the window doesn't stop recording; reopen from the menu bar.

### 5.5 After the meeting — mockup option A ("woven in")
- When the meeting ends (mic released / Aidan clicks Stop), Lyra finalises the transcript, then Claude
  expands the notes:
  - Aidan's lines stay in normal (white) text, untouched.
  - Claude's additions sit directly under the relevant line in grey.
  - Important things Aidan didn't note appear as extra grey bullets.
- Below: the full transcript with timestamps, names, name-source badges, and click-to-rename.
- Slide screenshots appear inline in the expanded notes at the moment they were shown.
- Re-running the expansion after renaming speakers should be possible.

### 5.6 Slide / scene screenshots
- Only when Aidan chose "Allow + capture slides".
- Watch **only the meeting window / shared-screen area**, never the whole desktop.
- About once a second; save a screenshot when the picture changes meaningfully (new slide, new
  scene, switched share). Ignore cursor movement, webcam tiles, small flicker.
- No duplicates when a presenter flips back to an earlier slide.
- Each screenshot is time-stamped and its text read (OCR) so it is searchable.
- In-person: not available (projector isn't on screen).

### 5.7 Where things are saved
- **Obsidian note** per meeting (in the vault at
  `~/Documents/Obsidian Vault/Aidan Business/`) containing: expanded notes,
  slide images (embedded), full transcript.
- **Recordings folder** per meeting: both audio tracks + screenshots. Linked from the note.
- **People database** (names, IDs, voice fingerprints): on the Mac only, never synced.

## 6. How it's built — Claude's calls (Aidan delegated the technical side)

- **Native macOS app in Swift / SwiftUI.** Required for a menu-bar-only app with direct app-audio and
  window capture. Own folder: `~/Documents/lyra/`, own git repo, separate from Leo.
- **Target:** Aidan's Mac — Apple Silicon (arm64), 48 GB RAM, macOS 27.2. No need to support older
  macOS or Intel.
- **Capture:** Apple's built-in frameworks (ScreenCaptureKit and/or Core Audio process taps for app
  audio; ScreenCaptureKit for window frames). No virtual audio drivers.
- **Language: English only** (Aidan's meetings are always in English) — English-optimised models are fine.
- **Speech-to-text, diarization, fingerprints: fully on-device.** Library choice left to builder;
  candidates that run natively on Apple Silicon: FluidAudio (Parakeet ASR + diarization + speaker
  embeddings, CoreML), WhisperKit/SpeakerKit (Argmax). Pick by accuracy on real multi-speaker audio.
- **OCR / tile-name reading:** Apple Vision framework (on-device).
- **Note expansion:** Claude via Aidan's **subscription**, by calling the Claude Code CLI
  (`claude -p`), not the paid API. Mirror Leo's `lib/claude-code-cli.ts`: strip
  `ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` from the environment, lean flags
  (`--tools ""`, `--setting-sources ""`, `--strict-mcp-config`, `--no-session-persistence`). If the
  call fails, still save the note with Aidan's notes + transcript unexpanded; never lose the meeting.
- **Distribution:** built and run locally on Aidan's Mac (signed with a local/dev identity). No App
  Store, no notarisation needed unless it becomes necessary for permissions to stick.
- **Starts at login.**

### Claude's calls on details Aidan didn't specify (he can overrule)
- **Note location:** default `Aidan Business/Meetings/YYYY-MM-DD HHmm — <title>.md`. After the meeting
  the window offers a client picker; choosing a client moves the note to
  `Clients/<Client>/Meeting Notes/` (those folders already exist).
- **Recordings location:** `~/Documents/Lyra Recordings/YYYY-MM-DD HHmm — <title>/` (outside the
  vault so large audio files don't bloat Obsidian sync). Screenshots also copied/embedded into the
  vault via an attachments folder so the note renders.
- **Audio format:** compressed (e.g. AAC/M4A), one file per track. Kept indefinitely.
- **Title:** from the meeting app window/tab title; editable.
- **Ignore list:** "Ignore" on an app offers "always ignore this app".
- **What "Allow" covers:** plain Allow = record both audio tracks **and watch the meeting window
  for speaker names** (frames are read in memory, never saved). "Allow + capture slides" additionally
  **saves** slide screenshots. Speaker naming is the top feature, so it is never switched off by
  declining slides. Requires Screen & System Audio Recording permission either way.
- **Source of truth:** Lyra's own store (meeting data + people DB) is the master; the Obsidian note is
  generated from it. Lyra writes the note with clearly marked sections. On rename / re-run expansion,
  Lyra regenerates only its marked sections; if Aidan has edited the note in Obsidian since Lyra last
  wrote it, Lyra asks before replacing anything. Click-to-rename lives in Lyra's post-meeting window.
- **Benchmark audio:** start with public multi-speaker test recordings, then Lyra's own first real
  calls (recorded with consent). Granola keeps no audio, so there is no back catalogue.
- **Code signing:** a stable local signing certificate created on Aidan's Mac (no paid Apple Developer
  account needed), so macOS keeps Microphone / Screen Recording permissions across rebuilds.

## 7. Left to the builder

- Exact libraries and model sizes for ASR / diarization / embeddings (benchmark on real audio).
- Confidence thresholds and how evidence from the three sources is combined.
- Slide-change detection method and thresholds.
- Echo-removal approach between tracks.
- Database format for people (e.g. SQLite in Application Support).
- Live vs post-meeting transcription split (live can be rougher; final pass after the meeting).
- App icon and menu bar glyph (keep sleek; dark-friendly).

## 8. Known risks to check early

1. App-audio capture with system volume fully muted.
2. Diarization quality on a single laptop mic in a room of ~15 people (workshop case).
3. Reading active-speaker tiles reliably across Zoom, Meet, Teams, FaceTime layouts.
4. Detecting meetings in browsers (Meet) — mic-in-use attribution to the browser + tab title.
5. macOS permission prompts (Microphone, Screen & System Audio Recording) persisting across rebuilds.
