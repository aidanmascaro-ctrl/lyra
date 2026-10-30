# Lyra sidebar and folders

*Date: 2026-10-30. Builds on `2026-10-27-lyra-phase-3-notes-design.md` (series, NoteIndex, the one window).
Where they disagree on where a note's file lives, this document wins.*

## 1. What it is

A sidebar down the left of Lyra's window that Aidan can show and hide. In it he keeps his own **folders**
("Clients", "Content", "Personal"…), each with a colour, and files notes and meetings into them by dragging.

Success: he presses the sidebar button (or ⌘\), sees his coloured folders, drags a meeting from the home list
onto "Clients", watches it land there, opens Clients to see what is in it, drags one note across to "Content",
and finds the same folders in Obsidian.

## 2. Decided with Aidan (2026-10-30)

1. **Folders are real folders in the vault**, under `Meetings/`. Dragging a note into a folder moves its file
   there, so Obsidian shows the same filing.
2. **Folders are separate from series.** A series stays what it is: the `series:` line in a note, its series page,
   and Claude's context. A meeting can be in a series and in a folder at once.
3. **When a series meeting is dragged into a folder, only its file moves.** It stays in its series through the
   `series:` line, and the series page still links to it. Each meeting drags on its own. The series folder then
   holds its page plus any meetings not filed in a folder.
4. **A hidden marker file tells a sidebar folder apart from a series folder**: `Meetings/<Folder>/.lyra-folder.json`,
   holding the folder's colour. Obsidian doesn't show hidden files. A folder made by hand in Obsidian is ignored
   by the sidebar (and still reads as a series, as today) until it is made in Lyra.
5. **One level.** Folders don't hold folders.
6. **One folder per note.** Dragging a note to another folder moves it there.

## 3. Anti-goals

- A broken `[[link]]`, a lost series, or a note filed into the wrong place without Aidan dragging it there.
- Anything permanently deleted. Removing a folder moves its notes out first, then puts the empty folder in the Trash.
- Writing to My notes. The only note writes this feature makes are the file move and, when needed, the `series:`
  line in frontmatter (§4.3), both through NoteIndex's lock and conflict rules.
- A drag that feels like a file manager: no "are you sure?" on a move, no dialog to pick a folder.

## 4. How it works

### 4.1 On disk

```
Meetings/
  Clients/                      ← sidebar folder (has the marker)
    .lyra-folder.json           ← {"colour": "blue"}
    2026-10-26 1655 — Elm Park … Workshop 1- Discovery.md   (series: Elm Park Startup Series)
    2026-10-27 2024 — Securing Two-Year Warranty ….md
  Elm Park Startup Series/   ← series folder (no marker)
    Elm Park Startup Series.md   ← series page, still links every meeting in the series
    2026-11-02 0900 — … Workshop 2- Strategy.md
  2026-10-27 2202 — Test 2.md   ← not in a folder
```

- A note's **folder** is the sidebar folder its file sits directly in, or none.
- A note's **series** is unchanged from today, except that a sidebar folder never counts as a series: a note in
  `Meetings/<X>/` belongs to series X only if X has no marker; otherwise its series is its `series:` line.
- Folder names follow series-name rules (`MeetingPaths.sanitise`: no `/ : \ ? * " < > # [ ] ^ |`), trimmed, not
  empty, and not the name of an existing folder of either kind (case-insensitive).

### 4.2 Where Lyra puts a note's file

Today `NoteIndex.relocate` always files a note at `Meetings/<series>/` (or `Meetings/`). From now on:

- **In a sidebar folder** → the note stays in that folder whatever happens to its title or series (retitle,
  Add to series, the after-meeting step).
- **Not in a sidebar folder** → as today.

So the after-meeting step finishing late can never pull a note back out of the folder Aidan dragged it into.

### 4.3 Moving a note into, between and out of folders

- **Into / between folders**: the file moves to `Meetings/<Folder>/` keeping its name. If a file of that name is
  already there, ` (2)` is added and `[[links]]` are rewritten, as relocate does today. Links by name keep working
  because the name doesn't change.
- **Leaving a series folder**: if the note's series came only from the folder it sat in (no `series:` line, e.g.
  Aidan moved it there in Obsidian), Lyra first writes `series:` so the meeting stays in its series. Its series
  page is rewritten afterwards (links are by name, so normally nothing changes).
- **Out of folders** ("Unfiled", §5.3): the file goes back where §4.2 would put it without a folder: its series
  folder, or `Meetings/`.
- A move happens off the main actor under the NoteIndex write lock. An open meeting keeps working: it finds its
  note again by `lyra_id`, as it already does after a series move.

### 4.4 Folder actions

- **New folder**: makes `Meetings/<Name>/` and its marker, colour picked from the palette in turn.
- **Rename**: renames the directory (marker moves with it). Notes keep their file names, so no links change.
  Refused, in plain English, when the new name is taken.
- **Colour**: rewrites the marker. Palette of eight muted colours that read on the dark page and on light:
  grey, red, orange, yellow, green, teal, blue, purple.
- **Remove folder…** (confirm): moves every Lyra note out as in §4.3, then puts the folder (now just its marker)
  in the Trash. If the folder still holds anything else (a file Aidan put there in Obsidian), Lyra leaves the
  folder alone after moving the notes out and says so in plain English. Nothing is deleted.
- Folders are listed by name. (Drag to reorder folders: not now.)

## 5. The sidebar

### 5.1 Showing and hiding
- A **sidebar button** (`sidebar.left`) in the title bar just right of the traffic lights, in the same quiet pill
  as the back pill (which shifts right to make room).
- **⌘\** and **View › Show Sidebar / Hide Sidebar** do the same.
- It slides in and out from the left (spring, ~0.3 s); the page beside it narrows smoothly with it.
- Lyra remembers whether it was open. Hidden by default the first time.
- In a narrow window (under ~760 pt) the sidebar overlays the page instead of narrowing it.

### 5.2 Look (Granola)
- About 240 pt wide, the same flat warm grey as the page, separated by a hairline, no material blur. Reaches up
  under the title bar (seamless; traffic lights float over it).
- Rows: **Home** (house icon), then a small "FOLDERS" header with a **+** to add a folder, then one row per folder:
  coloured folder glyph, name, note count in quiet grey. Rows light up softly on hover; the current page's row
  has a pill background.
- Each folder row has a disclosure chevron. Expanded, it lists its notes (title only, one line) indented under it;
  these rows open the note and can be dragged.
- Minimal scroller, as elsewhere.
- Empty state: "Make a folder, then drag meetings into it."

### 5.3 Folder page
Clicking a folder shows a page in the main area, like home's Recent list: the folder's coloured glyph and name as
the serif title, then its notes newest first (title, series, date). Right-click a row: Move to Trash (as home),
Remove from folder. Route: `.folder(name)`.

**Unfiled**: dragging a note onto **Home** in the sidebar takes it out of its folder (§4.3).

### 5.4 Right-click on a folder
Rename… (inline text field in the row, Return to save, Esc to cancel), Colour ▸ (eight swatches, current ticked),
Remove folder… (confirm, explains that notes stay and move back out).

## 6. Drag and drop

**Sources**: any meeting row: home's Recent list and series cards, a folder page, the sidebar's expanded folder
lists.

**Targets**: sidebar folder rows, the Home row (= Unfiled), and the folder page itself (drop anywhere on it).

**Feel** ("free flowing"):
- Native macOS drag (SwiftUI `draggable` / `dropDestination`, a Lyra-private type carrying the `lyra_id`), so the
  row lifts under the pointer as a translucent capsule with its title, and springs back if dropped nowhere.
- A target under the pointer **lights up in its folder's colour** (soft fill + 1 pt ring) and its glyph opens
  (`folder` → `folder.fill`), animated with a quick spring. Dropping on the folder the note is already in shows
  no highlight.
- Hovering a collapsed folder for ~0.7 s while dragging **springs it open**, so Aidan can see where it lands.
- On drop the move shows **at once** (the row leaves its list and appears in the folder's list with a spring,
  the count ticks), and the file move runs in the background. If the move fails, the row returns and a short
  plain-English notice says why.
- While the sidebar is hidden, dragging a row toward the window's left edge for ~0.5 s slides the sidebar out so
  it can be dropped. *(Builder's call whether macOS lets SwiftUI see this; drop if not possible cleanly.)*

## 7. Testing

- LyraCore: folder store (list, create, rename, colour, remove, name rules, marker ignored by Obsidian-facing code),
  series reading skips marker folders, relocate keeps a filed note in its folder, moving in/between/out keeps the
  series (writes `series:` when needed) and links, nothing deleted. All in temp dirs.
- App: sidebar visibility persistence and the toggle, optimistic move and roll-back in the sidebar model.
- Screenshots (debug build on scratch copies): sidebar open and hidden, dark mode, a folder page. Aidan checks drag
  feel himself.

## 8. Left to the builder
Exact sizes, colours' RGB values, spring constants, where the View menu item sits, how the optimistic list is
reconciled with the reloaded one.
