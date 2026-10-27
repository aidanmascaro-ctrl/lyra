# Lyra Phase 3 — the notes app

*Date: 2026-10-27. Builds on `2026-10-27-lyra-design.md` (the whole-app design) and Phases 1–2
(recording, transcript, named speakers). Where this document and the original design disagree,
this one wins for Phase 3.*

## 1. What it is and why

Phase 3 turns Lyra from a recorder into the place Aidan **works with** his meetings — a
replacement for Granola that keeps everything on his Mac and in his Obsidian vault.

After using Granola, Anarlog and Meetily, what he wants is:

- **A blank canvas to type in during a meeting.** Simple, clean, enjoyable — the Granola editor
  feel: serif title, plain text, easy bullets and numbered lists, a little formatting.
  Taking notes is **optional**: Lyra records and transcribes whether or not he types.
- **Three views of every meeting:**
  1. **My notes** — exactly what he typed, word for word. Never changed by Lyra or Claude.
  2. **Expanded** — Claude fleshes his notes out from the transcript after the meeting.
  3. **Transcript** — the raw record, every line with its speaker (Phases 1–2).
- **Expanded notes he can keep shaping.** Granola's version wrote itself top to bottom after
  the meeting (he liked watching that), but then it was *rigid*: he couldn't move ideas
  around, highlight a topic and ask for more, or inject his own ideas and have them fleshed
  out with the meeting's context. Lyra's expanded notes are a draft he keeps working on.
- **Series.** Many meetings are part of a run — e.g. "Elm Park Startup Series | Workshop 1:
  Discovery", then Workshop 2, 3… Lyra groups them, and when expanding or answering
  questions inside one, it draws on the earlier ones in the same series.
- **Good titles, tags and links**, so meetings link together in Obsidian into his "business
  brain", and so Claude can later answer "what did the leader say in the discovery session?"
  by reading the vault.

**Who reads the output:** Aidan (in Lyra, and in Obsidian) and Claude (in future sessions,
reading the vault). Every note must make sense to both: real names, meaningful titles, topic
tags, links to clients/people/series.

**Success looks like:** after a call he opens Lyra, sees the meeting in its series with a good
title, flips between his raw notes, the expanded notes and the transcript, highlights a point
and gets more on it, drags ideas into order, and finds it all in Obsidian too — edits in
either place show up in the other.

## 2. Goals

- A **home window** (Granola-style) opened from the menu-bar icon: series and recent meetings,
  plus a **New note** button for the meeting happening right now.
- A **meeting window** with three tabs: My notes / Expanded / Transcript.
- A **simple rich-text editor**: bold, underline, two heading sizes, bullet lists, numbered
  lists, indent/outdent. Markdown shortcuts as you type (`- `, `1. `, `# `, `## `) plus
  ⌘B / ⌘U. Nothing more (no colours, fonts, tables, images in the editor).
- **Expanded notes**, written by Claude after the meeting, streamed in top to bottom, then
  fully editable: edit any text, drag bullets/headings to reorder, highlight → *Expand this* /
  *Find in transcript* / *Ask*, and a bottom bar to ask about the meeting or inject an idea.
- **Series**: suggested by Lyra, confirmed by Aidan, used as context for Claude.
- **Title, tags and links** worked out after the meeting from the window title, what was on
  screen, and the transcript.
- **Two-way with Obsidian**: the Obsidian note *is* the storage; editing in Obsidian shows in
  Lyra and vice versa.
- **Detection polish** from today's use: an "Always ignore this app" choice on the Allow popup.

## 3. Non-goals (Phase 3)

- Searching or asking across **all** meetings ("what has anyone told me about pricing?") —
  later. Phase 3 context is this meeting + its series.
- Pulling Obsidian **client notes** into expansion — later.
- Importing old Granola notes.
- Slide screenshots, active-speaker tile reading — Phase 4 as planned.
- Sharing, cloud sync, mobile, multi-user.

## 4. Anti-goals (a failure even if it works)

- **Changing what Aidan typed** in My notes. Ever. Not Claude, not a sync, not a reformat.
- **Losing typed notes** — a crash, quit or sleep mid-meeting must not lose a word he typed.
- **Silently overwriting an edit** made in Obsidian or in Lyra.
- **Filing a meeting into the wrong series without asking** — a wrong grouping pollutes the
  brain, like a wrong name does. Lyra suggests; Aidan confirms.
- **Rigid output** — Claude's text that can't be edited, moved or questioned.
- Anything leaving the Mac other than the prompt text sent to Claude via his subscription.
- A cluttered editor. If it stops feeling like a blank canvas, it's wrong.

## 5. How it works — decided with Aidan

### 5.1 Home window
- Clicking the menu-bar icon opens the home window (the menu keeps Stop / Start in person /
  Teach my voice / Quit — exact split left to builder).
- Top: **New note — <app> (live)** button while a meeting is being recorded. Clicking it opens
  the meeting window on the My notes tab, ready to type.
- **Series** section: each series with its meeting count, tags/client link, and its meetings
  newest first.
- **Suggestion card** when Lyra thinks a meeting belongs to a series: "'X' looks like part of
  *Series* — Add to series · Not related".
- **Recent**: all meetings, newest first, with series name and date.
- Mockup: `.superpowers/brainstorm/28354-1793072619/content/home-series.html`.

### 5.2 Meeting window
- Serif, editable title at the top; below it a line with date, series, tags and links.
- Three tabs: **My notes**, **Expanded**, **Transcript**.
- My notes is available from the moment recording starts (via New note). During the meeting
  it's the only tab with content; Expanded and Transcript fill in after processing.
- Transcript tab keeps Phase 2's click-a-speaker-to-rename.
- Notes are saved continuously as he types (crash-safe), not only on close.
- **Live transcript drawer** (decided with Aidan, Granola-style): during the meeting, a small
  control at the bottom of the window toggles a drawer that slides up showing the transcript
  as it's spoken, and hides away again. Hidden by default so the page stays a blank canvas.
  - Live text is a rough draft: on-device streaming speech-to-text, labelled by track only —
    **Me** (mic) and **Them** (meeting audio). *Claude's call:* proper speaker names need the
    whole-recording pass, so names arrive after the meeting.
  - When processing finishes, the Transcript tab holds the full, named transcript; the live
    draft is thrown away, not saved.
  - Live transcription must never put the recording at risk: if it falls behind or fails, the
    drawer says so and the recording carries on.

### 5.3 Expanded notes
- When the transcript is ready, Claude writes the expanded notes, **streamed in top to bottom**.
  Structure follows Aidan's notes: each of his points stays, with Claude's detail under it;
  important things he didn't note appear as extra points.
- **Claude's words are grey; his are white.** When he edits a grey passage it becomes his
  (white). The distinction must survive saving and show in Obsidian too.
- Everything is ordinary editable text. **Drag handle** on bullets and headings to reorder.
- **Highlight → menu:**
  - *Expand this* — more detail on that point from the transcript, inserted under it.
  - *Find in transcript* — switches to the Transcript tab at the relevant line(s).
  - *Ask…* — a question about the highlighted point; the answer is inserted right there.
- **Bottom bar** ("Ask anything or add an idea…"): a question about the meeting, or an idea to
  weave in ("add a section on how this ties into the Morningside collab"). Claude uses the
  meeting's context to write it in.
- **Context Claude gets:** this meeting's notes + transcript (with speaker names), plus the
  earlier meetings in the same series (their expanded notes and transcripts), within a
  budget. Earlier meetings are context only — Claude never edits them.
- Mockup: `.superpowers/brainstorm/28354-1793072619/content/expanded-notes.html`.

### 5.4 Series
- After a meeting, Lyra decides whether it belongs to an existing series, starts a new one,
  or is standalone, using the title, what was on screen, the transcript, and the existing
  series. Example: "Elm Park Startup Series | Workshop 2: Strategy" → series "Elm Park Startup
  Series".
- It's a **suggestion** shown on the home window and in the meeting window. Aidan confirms
  (*Add to series*) or rejects (*Not related*). Rejecting doesn't ask again for that meeting.
- Aidan can rename a series and move a meeting to another series (or out of one).
- In Obsidian: each series is a folder with a **series page**: every meeting in order, each a
  link plus **one short line on what was talked about** (decided with Aidan). No longer
  running summary. The one-liner comes from the same after-meeting Claude call that picks the
  title and tags (no extra call), is stored in the meeting's frontmatter, and the series page
  is regenerated by Lyra from those — Lyra owns that page.

### 5.5 Title, tags and links
- After the meeting Lyra proposes a title, using the meeting window's title (Phase 2), what
  was on screen during the call, and the transcript. The title is editable.
- **What was on screen**: Lyra reads text from the meeting window (on-device, Apple Vision) a
  few times during the call — e.g. the meeting name in a Zoom/Meet header, a slide title.
  Read in memory only, never saved as images (saving slides is Phase 4). Needs the Screen
  Recording permission Phase 2 already asks for; without it, title falls back to window
  title + transcript.
- **Tags**: a handful of topic tags (`#pricing`, `#content-strategy`, `#ai-consulting`),
  reusing tags already in his vault where they fit.
- **Links**: `[[Client]]` when a client from `Aidan Business/Clients/` is involved; `[[Person]]`
  for named speakers; the series page.

### 5.6 Obsidian, two-way
- The meeting's Markdown note in the vault is the **single storage** for the three sections.
  Lyra's editor reads and writes that file. No second copy, so nothing to sync.
- Change it in Obsidian → Lyra shows the change next time it's looked at (live if the window
  is open). Change it in Lyra → it's in Obsidian.
- If the file changes on disk while Lyra has unsaved edits to the same note, Lyra warns
  instead of overwriting.
- Formatting must be Markdown Obsidian shows: bold, `<u>underline</u>`, `#`/`##`, `-`
  bullets, `1.` lists, indentation.
- Lyra keeps writing the Transcript section (rename re-renders it) with Phase 2's
  ask-before-replacing-an-edited-transcript behaviour.
- In Obsidian the note reads as one page with three headings (My notes / Expanded /
  Transcript), plus frontmatter (date, series, tags, links, recordings folder).

### 5.7 Claude
- Runs through Aidan's **subscription** by calling the Claude Code CLI (`claude -p`), as in the
  original design (§6: strip `ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`,
  lean flags). Not the paid API.
- If Claude fails (offline, logged out, limit hit): the meeting is still complete — My notes and
  Transcript saved — and Expanded shows "Couldn't expand — Retry". Same for highlight actions.

### 5.8 Detection polish
- Allow popup gains **Always ignore <app>**. Ignored apps never prompt again; un-ignoring
  lives somewhere simple (e.g. a list in the menu). Mac speech/dictation services are already
  ignored (fixed 2026-10-27).
- **Start recording (in person)** stays in the menu (exists since Phase 1).

## 6. Claude's calls (Aidan can overrule)

- **Notes stay put in `Meetings/<Series>/`** (or `Meetings/` if standalone). The original
  design's "move the note into `Clients/<Client>/Meeting Notes/`" is dropped: series folders
  replace it, and the client is a `[[link]]` instead, so the client's page still lists every
  meeting via backlinks.
- **Taking notes doesn't pop up automatically** on Allow — "optional", so the New note button
  (home window, and a menu item) opens it.
- **Answers to bottom-bar questions** appear in a small reply under the bar with an *Add to
  notes* button, rather than always being inserted (a question isn't always worth keeping).
  Highlight → *Ask* inserts in place, since it's anchored to a point.
- **Re-expanding** after more renames or edits: an explicit *Re-expand* that rewrites only
  grey (Claude's) text, never white.
- **Phase 1/2 test notes** keep working (they have notes/transcript markers); no migration
  beyond what reading them needs.
- **Appearance** follows macOS light/dark; in dark it should look like the Granola screenshot.
- **Edited grey becomes his, wherever he edits it.** A grey passage (one bullet/paragraph) that
  Aidan changes — in Lyra *or* in Obsidian — becomes white as a whole, and Re-expand never
  touches it. To spot Obsidian edits, Lyra remembers the exact text it last wrote for each grey
  passage and compares before any rewrite.
- **Expanded is its own document after the first run.** Later changes to My notes don't flow
  into Expanded automatically. If My notes has points that Expanded doesn't cover yet, Lyra
  shows "2 new notes since — Re-expand", and Re-expand adds them (plus refreshes untouched grey).
- **File names follow the title.** The note's file is named once the title is settled at the end
  of processing (before anything links to it), and moves into `Meetings/<Series>/` when a
  series is confirmed. Later renames (title, series, series folder) are done by Lyra, which
  also rewrites `[[links]]` to the old name across the vault (exact link matches only). Lyra
  finds notes by the `lyra_id` in their frontmatter, not by path, so if Aidan moves a note
  into a series folder in Obsidian, Lyra treats that as joining that series. The recordings
  folder keeps its original name; the note's frontmatter points at it.

## 7. Left to the builder

- Editor technology (SwiftUI `TextEditor` with `AttributedString`, an `NSTextView` wrapper,
  or other) — whatever gives reliable Markdown round-trip and drag-to-reorder.
- How "Claude's text" is marked in the Markdown so it survives round-trips and shows grey in
  Obsidian (e.g. an inline span with a class plus a vault CSS snippet), as long as the file
  stays clean, readable plain text for a human and for Claude.
- Section markers in the file, file watching, debounce/save timing, conflict detection.
- Prompt design, streaming method, context budget and how earlier series meetings are trimmed.
- How often the screen is read and how series/titles/tags are decided (one Claude call or more).
- Window sizes, exact layout, keyboard shortcuts beyond ⌘B/⌘U.
