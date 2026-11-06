# Lyra

Personal macOS meeting recorder and notes app for Aidan Mascaro (Perth, WA). Granola replacement that keeps
everything on his Mac and in his Obsidian vault. Aidan has **no coding background**: Claude builds and
maintains everything. Explain in plain English, never ask him to edit code.

## Read first
- `docs/superpowers/specs/2026-10-27-lyra-design.md` — whole-app design (goals, anti-goals, roadmap).
- `docs/superpowers/specs/2026-10-27-lyra-phase-3-notes-design.md` — the notes app (current product truth; wins over the older design).
- `docs/notes/handoff-2026-10-27.md` — where things stand, open items, what to do next.
- `docs/notes/phase{1,2,3}-findings.md` — measured facts (calibration, audio, live transcript).

## Stack
- Swift 6 SwiftPM package (tools 6.0, Swift 6 mode), macOS 15+ floor, Apple Silicon. Bundle `au.aidos.lyra`.
- Targets: `LyraCore` (Foundation + CryptoKit only — all testable logic), `LyraAudio` (Core Audio taps, mic,
  ScreenCaptureKit + Vision), `LyraSpeech` (FluidAudio: Parakeet ASR, diarizer, live sliding-window ASR),
  `Lyra` (SwiftUI/AppKit app). Tests: `LyraCoreTests`, `LyraAppTests`, `LyraIntegrationTests`
  (gated: `LYRA_INTEGRATION=1`).
- Claude via Aidan's **subscription** only: `claude -p` CLI (`Sources/LyraCore/Claude/ClaudeCLI.swift`), with
  `ANTHROPIC_API_KEY`/`BASE_URL`/`AUTH_TOKEN` stripped. Prompts live only in `Sources/LyraCore/Claude/Prompts.swift`.

## Commands
```bash
swift test                                   # all unit tests
LYRA_INTEGRATION=1 swift test                # + real audio/speech/Claude checks
scripts/build-app.sh                         # builds build/Lyra.app (ad-hoc signed)
scripts/install-app.sh                       # quits Lyra, installs to /Applications, reopens
```
Before installing, make sure nothing is recording (Aidan says so, or no fresh `.caf` in a meeting folder).

## Where data lives
- Notes: `~/Documents/Obsidian Vault/Aidan Business/Meetings/` (series = subfolder + series page). The note is
  the single store for My notes / Expanded / Transcript (section markers `<!-- lyra:…:start/end -->`).
- Recordings: `~/Documents/Lyra Recordings/YYYY-MM-DD HHmm — title/` (meeting.json, transcript.json,
  speakers.json, M4As). People + voice fingerprints: Application Support (owner-only files).

## Rules that must not break
- **My notes is never written by Lyra or Claude** — only Aidan's typing. Lyra writes Expanded only
  (`NoteSync.writeExpanded`), frontmatter, and Transcript.
- **Never silently overwrite** an edit made in Lyra or Obsidian (NoteIndex write lock + fingerprints + NoteSync conflicts).
- **Nothing is permanently deleted** — `FileManager.trashItem` only.
- Never record without Aidan's Allow click — the one exception: he pressed **Join** on an upcoming meeting in
  Lyra and the meeting app then takes the mic (see `docs/superpowers/specs/2026-10-27-lyra-calendar-design.md`). Voice fingerprints never leave the Mac.
- Wrong names/series are worse than none: series is always a suggestion Aidan confirms.
- **This repo is public.** Never commit real client or people names, real meeting content, prices, personal
  emails or home-folder paths: tests and docs use made-up examples. Never commit `Resources/CalendarApps.json`
  or `handoffs/`, and never share a built `Lyra.app` (it contains the Google client secret). Commits use the
  GitHub noreply address, set in this repo's git config.

## Working with Aidan
- **Never send synthetic clicks or keystrokes on his Mac** (an agent once typed into his Chrome). Verify UI with
  screenshots of Lyra's own windows (`screencapture -l <windowID>`; debug builds read `LYRA_DEBUG_OPEN`,
  `LYRA_DEBUG_TAB`, `LYRA_DEBUG_WIDTH/HEIGHT`) and leave interaction checks to him.
- He reviews by eye: send screenshots of UI work. He loves Granola's look — seamless title bar, flat warm grey
  (~#292929), centred column, serif titles, pill rows, pill bottom bar, minimal scrollers. Dark first.
- Process: superpowers brainstorming → written design → plan → subagent-driven build with a review per task.
- Never test against his real notes; use temp dirs or scratch copies.
