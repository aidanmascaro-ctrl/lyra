# Lyra — names from the conversation

**Status:** approved by Aidan, 10 Nov 2026 (option "fill in sure ones").

## Problem

After a meeting, Lyra names a voice only when it already knows it (voice fingerprint) or reads it off a lit
call tile. Everyone else is "Speaker N". In a busy call people introduce themselves and talk to each other by
name the whole way through, and none of that is used.

## What it does

A new after-meeting step, run before Claude titles and expands the meeting, so both use the names:

1. Claude reads the transcript (speaker labels, times, text) plus the screen text and the people Lyra knows.
2. For each "Speaker N" it may give one name, with **evidence**: short quotes copied word for word from the
   transcript, and whether it is **sure**.
3. Lyra checks the answer itself before using any of it (below). Every checked name is saved in
   `heardnames.json` in the recording folder.
4. **Sure** names go straight into the transcript (`nameSource = .heard`, badge "from the talk"); the note's
   transcript section is re-rendered if Aidan hasn't edited it. **Unsure** names stay suggestions on the pill.

The same step can be run by hand on an older meeting: **Suggest names** on the Transcript tab.

## What counts as evidence (told to Claude)

- Self-introduction: "I'm Sam", "Sam here", "my name's Sam".
- Being spoken to by name, where that speaker answers next: "Thanks, Sam", "Sam, what do you think?"
- Being talked *about* ("Sam sent the file") never counts on its own.
- Screen text and known people are candidates only, never evidence.

## Lyra's own checks (Claude's answer is never trusted as is)

- Only placeholder voices ("Speaker N", no person, no name source) can be named.
- Every quote must really appear in the transcript (case and spacing ignored). No real quote: dropped.
- One name per speaker, one speaker per name: two speakers given the same name both stay unnamed.
- Never a name already on another speaker in this meeting, whole or by first name (so never Aidan), never
  "Speaker N", never blank, never longer than 40 characters.
- Claude's "sure" stands only if one quote proves the voice by Lyra's own reading of the transcript; otherwise the
  name becomes a suggestion:
  - the voice's own line introduces itself ("I'm Sam", "my name's Sam", "Sam here"; not "this is Sam", not
    "I'm Sam's…"), or
  - someone else's line ends on a sentence with the name that isn't a thank-you, the next voice to speak is this
    one, and it wasn't also the voice just before (that would be a remark to whoever finished).
- Tried on a scratch copy of a real 11-voice workshop: about 4 names sure, about 6 suggestions, 1 left unnamed.
  The one doubtful pairing became a suggestion.

## Safety around edits and resumes

- Claude's answer is applied to the transcript as it is *after* Claude answers, so a rename Aidan makes
  meanwhile always wins. Rename pills are locked while Suggest names runs; the meeting counts as busy.
- An unreadable `heardnames.json` stops the run rather than being written over.
- Resuming a recording lets naming run again for the new voices; only names already in the transcript and
  Aidan's "Not them"s carry over, and "Not them" never gives two voices one label.

## Aidan's controls (Transcript tab)

- Pill of a heard name: badge "from the talk"; clicking shows the quotes with **Yes, that's them** (becomes
  `.setByAidan` and Lyra learns the voice, through the normal rename), **Not them** (back to "Speaker N", and
  remembered so a re-run won't bring it back), or a different name.
- Pill of an unsure suggestion: "Speaker 5 · Sam?" with the same quotes, **Yes** or **Not them**.
- A heard name is never learned as a voice until Aidan says yes.

## Not done here

- Calendar invite names: Lyra only stores a head count for events today.
- Fixing why the Zoom screen capture came back empty (separate track).
- Expanded notes already written before Suggest names ran keep "Speaker N"; Re-expand picks up the names.
