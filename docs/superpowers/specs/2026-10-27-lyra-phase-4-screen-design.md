# Lyra Phase 4: names from the call's tiles, and slide screenshots

*Date: 2026-10-27. Decided with Aidan the same day. Builds on the whole-app design (§5.3 step 2, §5.6) and
replaces it where they differ.*

## 1. What Aidan asked for

- **Apps:** all of them: Google Meet, Teams and Zoom in Chrome, the Zoom app, WhatsApp, FaceTime and Discord.
- **Names from tiles:** when the call shows who is talking (a lit tile with a name) and Lyra is sure, the
  speaker gets that name **and Lyra learns the voice**, so that person is a known voice next time.
- **Slides:** saved only when Aidan **switches it on** for that meeting. They are **linked, not embedded**:
  they go into the recordings folder, and the note gets one link to them.

## 2. Anti-goals

- **A wrong name.** Tiles name a speaker only when the evidence is strong and one-to-one. Anything unclear
  stays "Speaker N". Renaming a tile-named speaker also takes the wrongly learned voice back out.
- **Capturing anything but the call.** Lyra watches only the call's own window. In a browser, that is only a
  window whose title is the call. It never watches Gmail in another tab, or the desktop.
- **Saving pictures without the switch.** Tile reading is always on during a call, but frames stay in
  memory. Only names and times are kept (`onscreen.json`). Lyra saves pictures only when Slides is on.
- **Slowing the call down.** Lyra reads one frame a second, at window size, and runs OCR only on a lit tile
  or a new, still slide.

## 3. How it works

### 3.1 Watching the call window (`CallWindowWatcher`, LyraAudio)
- Runs while a call recording records (Allow or Join; it has a meeting app). It sleeps during Pause. A
  plain mic recording (New note → Record, Resume after End) has no call window, so it doesn't run.
- Finds the window: the meeting app's largest on-screen normal window. For a browser, the window's title
  must name a call site (Meet, Teams, Zoom, Webex, Whereby, Jitsi) or match the title at Allow. No match
  means no frame that second. The existing once-a-minute `ScreenText` uses the same rule.
- Each second, it captures one frame with ScreenCaptureKit, the same way `ScreenText` does. The time it
  stamps is on the recording's own timeline (seconds since recording began, less paused time), so it lines
  up with transcript times.

### 3.2 Who is talking (`SpeakingTile`, LyraCore, pure)
- Every app marks the talker with a coloured outline round their tile: Zoom green, Meet blue, Teams
  purple, Discord green. Lyra doesn't hard-code those colours. On a small copy of the frame, it looks for
  a **hollow ring** of one saturated colour: a large, thin outline with almost nothing inside. A green
  shirt, a logo or a filled button is not hollow, so it doesn't count.
- Lyra reads the text inside the ring (Vision OCR on that crop only). The name is the lowest line that
  looks like a person's name (`TileName`). That means 1–4 words of letters, with labels like "(Host)",
  "(You)" and "| Company" taken off. Device and room names are refused: "iPhone", "MacBook", "Galaxy",
  "Room", "Boardroom", "Zoom Room", "Presentation", "Guest", numbers and email addresses.
- Each second gives at most one sample: `{t, name}`, or no name. The samples are appended to
  `onscreen.json` every 30 s and again at stop, so a crash keeps them.
- Layouts with no ring, such as Zoom speaker view and FaceTime's enlarging tile, give no samples. Those
  voices fall back to known voices and "Speaker N". No guessing.

### 3.3 Naming from the samples (`OnScreenNamer`, LyraCore, pure)
Runs in processing after the known-voice naming, on **call-track** voices that are still unknown. Aidan's
mic and anyone in the room with him have no tile.
- For each voice (cluster), Lyra counts the samples inside its lines, skipping each line's first 0.5 s,
  because the ring lags the voice. That gives votes per name.
- **Sure** = at least 6 votes (about 6 s of lit tile while that voice spoke) **and** at least 75% of that
  voice's votes for one name.
- One name, two voices: if the voices sound alike (cosine ≥ 0.60), the diarizer split one person in two,
  and both get the name. If they don't, it's a shared room or device, and neither gets it.
- A name already in the people list joins that person. A new name creates a new person.
- Lines get `nameSource: .onScreen` and `confidence` = the vote share. The transcript shows them as
  *on screen*: `_(on screen)_` in the note, "on screen" in Lyra.
- **Learning:** each tile-named voice is learned into that person (`PeopleStore.learn`). From the next
  meeting it is a known voice. If learning fails, the name stays and the note warns.
- **Renaming fixes it fully:** renaming a speaker whose lines came from tiles removes that voice sample
  from the person it was learned into (`PeopleStore.forget`), then learns it under the new name.

### 3.4 Slides (`SlideWatcher`, LyraCore, pure; files written by the app)
- **Off at the start of every recording.** It's switched on per meeting: **Allow + slides** in the Allow
  panel, or the Slides button in the bottom bar while a call records. The button also shows the number of
  slides saved so far.
- Each second, Lyra makes a 64×36 grey thumbnail of the frame. A frame becomes a candidate when it has
  stayed still for 2 s (so no slide transitions) and differs from the last slide saved.
- Lyra reads a candidate's text (OCR). It counts as a slide if it has at least 8 words other than tile
  names, or shows a sharing cue ("is presenting", "viewing … screen", "sharing"). A gallery of faces fails
  this. Lyra remembers the frame so it doesn't check it again.
- **No duplicates:** each saved slide keeps a 64-bit picture hash. A frame within 6 bits of any saved
  slide (a presenter flipping back) is skipped.
- Saved as `slides/001 00-03-12.jpg` (JPEG at 0.9, full window) in the meeting's recordings folder.
  `slides.json` lists each slide's file, time and text, so the slides are searchable. Slide text also goes
  into `screenText`, which the insights step already reads.
- `slides/` and `slides.json` stay at the top of the folder when Resume after End files a part away.
  `onscreen.json` is filed with its part, because its times belong to that part.

### 3.5 In the note and in Lyra
- **Obsidian:** when a meeting has slides, the line under the title gains
  ` · [12 slides](file:///…/slides/)`. Clicking it opens the folder in Finder. Lyra puts the link back on
  each render, like the rest of that line, and the count lives in the frontmatter (`slides: 12`).
- **Lyra:** the meeting header gets a "12 slides" pill that opens the folder. The transcript shows
  "on screen" beside tile-named speakers.

## 4. Testing
- **Unit tests (LyraCore):** synthetic frames for the ring finder; name cleaning; namer vote rules (sure,
  unsure, shared tile, split voice, known voice wins, lag skip); slide rules (still, changed, flip-back
  duplicate, gallery rejected); the note's jump line with the slides link; rename forgetting a
  tile-learned sample; parts keeping slides at the top.
- **Integration test (`LYRA_INTEGRATION=1`):** Lyra opens its own window drawn like a call (tiles, one
  lit with a name, then a slide). It captures that window through ScreenCaptureKit and Vision, and checks
  the name and the saved slide. That covers real capture without a real call or touching Aidan's screen.
- **Aidan's check:** one real call with slides switched on (Meet or Zoom, another person or a second
  device). Afterwards, the note has a slides link, and the speaker is named "on screen".

## 5. Not in this phase
- Embedding slides in the note, or placing them by time in Expanded (Aidan chose a link).
- Naming from speaker-view layouts with no ring, or from conversation clues (§5.3 step 3).
- Giving slide text to Claude's expansion. Only insights reads it, through `screenText`.
