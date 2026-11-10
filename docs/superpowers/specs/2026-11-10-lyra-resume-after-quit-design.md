# Lyra — Resume after Quit

## What Aidan sees

- **Closing the window** keeps recording; the menu-bar icon stays. (Already true; unchanged.)
- **Quit** while recording stops the recording and keeps everything recorded so far. Nothing is written up yet.
- **Next launch**: Home shows a card at the top — "Recording stopped when Lyra quit · *title* · 3:12 pm" with
  **▶ Resume** and **Not now**.
  - **Resume** starts recording again straight away, into the same note. Nothing is lost while it starts. When he
    presses End, both halves are written up together into one transcript, as with Resume after End.
  - **Not now** writes the note up as usual. He can still press Record in the note later (Resume after End).
  - The note's own bottom bar offers Resume too while the offer stands.
- Lyra never starts recording by itself: Resume is always his click.

## How long the offer waits

While the offer stands, that note is not written up. The offer lasts **15 minutes** after launch (or until he
chooses); after that the note is written up as if he'd pressed Not now. Resume in the note still works afterwards.

## How it works

- On quit, `meeting.json` is marked `stoppedByQuit`. On launch, crash recovery leaves marked folders alone and
  they become offers; unmarked ones (a real crash) are written up as today.
- **Resume** files the unfinished part under `parts/N` (its audio, on-screen log and a copy of its `meeting.json`)
  — the same `parts/` folder Resume after End uses — and records the new part at the top of the folder. Recording
  starts at once: no transcribing first.
- **Writing up** first transcribes any filed part that was never transcribed (in order, in its own folder), then
  joins all parts as Resume after End already does. So quitting more than once in one meeting works too.
- If the meeting was a call and its app is still open, Resume records the call's sound again as well as the mic.
  Speaker tiles and Slides aren't watched in a resumed part (as for Resume after End).
- Crash safety: each filed part's `transcript.json` is written before its audio is removed; a crash anywhere
  leaves the folder recoverable on the next launch. If Resume can't start, the filed part is put back.
