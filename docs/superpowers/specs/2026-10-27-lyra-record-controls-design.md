# Lyra — record controls: New note without recording, Pause / Resume

Status: draft for Aidan's approval, 2026-10-27. Extends the Phase 3 notes design; wins over it where they differ.

## Why
- New note started recording straight away. Aidan wants a plain note, recording only when he asks.
- After Stop in a live note there was no way to record again in it.

## What Aidan sees
- **New note** opens a blank note. Nothing records. The bottom bar shows a **● Record** button at the left,
  beside "Ask anything".
- **● Record** starts recording into that note. The left capsule then shows, as today, the live dots (opens the
  live transcript) and now two buttons: **⏸ Pause** and **■ End**.
- **⏸ Pause** stops listening straight away: the mic is let go (the orange mic dot goes off) and so is the call
  audio. The capsule shows **▶ Resume** and **■ End**, and a quiet "Paused" label.
- **▶ Resume** carries on in the same recording, the same note and the same transcript. The paused time is simply
  left out.
- **■ End** finishes the recording and writes it up, as Stop does today (transcript with names, Expanded, title and
  tags).
- Calls Lyra detects work the same once he clicks Allow: Pause / Resume / End are there too. When the call
  ends, the recording ends and is written up, paused or not.
- Quitting Lyra or the Mac sleeping while paused ends the recording, as it does while recording.

## Not in this step
- Recording more into a note that has already been ended and written up. (That means writing it up again from
  both recordings; it can come later if he wants it.)
- An empty New note that is never recorded stays a plain note: nothing is written up and Claude never runs on it,
  except Ask, which works on the notes alone.

## How it works
- New note reserves the folder and makes the note as a recording does today, with `meeting.json` saying "no
  recording yet". Home and the trash treat it like any other note.
- Record on such a note starts a recording session in that existing folder instead of a new one.
- Pause stops both tracks' capture but keeps their files open; Resume starts capture again into the same files.
  Both tracks pause together, so they stay lined up. The live transcript keeps reading the files and so carries
  on after Resume.
- `meeting.json` keeps the pause and resume times, so a crash while paused is recovered like any recording.
- Never records without Aidan's click: Record, Resume and Allow are the only things that start capture.

## Checks
- Unit: recording state (record → pause → resume → end; end while paused; call ends while paused), New note makes
  a note with no recording, Record in that note uses its folder.
- Integration (gated): pause releases the mic; resume writes into the same file; total length leaves out the pause.
- Aidan: New note doesn't record; Record, Pause (orange dot goes off), Resume, End; a detected call paused then
  ended by hanging up.
