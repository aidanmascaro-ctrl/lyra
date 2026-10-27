# Phase 4 plan — tile names and slides

Design: `docs/superpowers/specs/2026-10-27-lyra-phase-4-screen-design.md`. Branch `feat/phase-4-screen`
(worktree `.worktrees/phase4`). Each task: failing tests → code → `swift test` green → review → commit.

1. **Tile names (LyraCore).** `TileName.clean(_:)` (labels stripped, device/room/email refused) and
   `SpeakingTile.find(in: PixelFrame)` (hollow single-hue ring → tile rect). Tests on synthetic frames.
2. **Naming from samples (LyraCore).** `OnScreenSample`, `OnScreenNamer.name(lines:clusters:samples:people:)`,
   `NameSource.onScreen`, note badge `_(on screen)_`. `MeetingProcessor` reads `onscreen.json`, names, learns
   through an injected `learn` closure, warns on failure. `PeopleStore.forget(sample:)`; `RenameService` forgets
   a tile-learned sample before learning the new name. `RecordingParts` files `onscreen.json` with its part.
3. **Slides (LyraCore).** `SlideWatcher` state machine over `Thumbnail` (64×36 grey, mean difference, 64-bit
   dHash): stillness, change since last saved, flip-back duplicates, remembered rejects, text/cue test.
   `SlideLog` (`slides.json`).
4. **Note link (LyraCore).** `NoteFrontmatter.slides`, jump line with `· [N slides](file:///…/slides/)`,
   parse accepts it. Processing sets the count.
5. **Capture (LyraAudio).** `CallWindow` (window rule from LyraCore `CallWindowRule`, ScreenCaptureKit
   capture, `PixelFrame`/`Thumbnail` from CGImage, OCR of a crop, JPEG write). `CallWindowWatcher` loop
   (1 Hz, timeline clock, pause, `onscreen.json` flush every 30 s). `ScreenText` uses the same window rule.
   Gated integration test against a window Lyra draws itself.
6. **App.** `MeetingSession` runs the watcher; slides switch (`Allow + slides`, bottom-bar button with count);
   header pill "N slides"; transcript badge "on screen".
7. **Verify and ship.** Scratch copy screenshots of Lyra's windows to Aidan; build; install when no `.caf`
   changed in the last 2 minutes; handoff notes.
