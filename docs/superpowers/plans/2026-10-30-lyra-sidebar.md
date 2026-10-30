# Lyra sidebar and folders — plan

Design: `docs/superpowers/specs/2026-10-30-lyra-sidebar-design.md`. Branch `feat/sidebar`, worktree
`.worktrees/sidebar`. Each task: tests first, `swift test` green, one commit (`feat: …`), then a review.
Never touch the real vault or recordings: tests use temp dirs; screenshots use scratch copies via
`LYRA_NOTES_DIR` / `LYRA_RECORDINGS_DIR` / `LYRA_PEOPLE_FILE`.

## Task 1 — LyraCore: folders on disk

New `Sources/LyraCore/Folders/`:

- `SidebarFolder` (`name`, `colour: FolderColour`), `FolderColour` enum (grey, red, orange, yellow, green, teal,
  blue, purple; `Codable`, `CaseIterable`).
- `MeetingFolders` (struct over `NoteIndex`, `Sendable`):
  - `static let markerName = ".lyra-folder.json"`; `isFolder(_ url:)` = directory directly under `notesRoot` with the marker.
  - `all() -> [SidebarFolder]` sorted by name (localized, case-insensitive). Unreadable marker → grey.
  - `create(_ name:) throws -> SidebarFolder` (name rules §4.1, colour = next in palette after the existing count),
    `rename(_:to:) throws` (directory move, case-only rename via temp name like `renameSeriesFolder`),
    `setColour(_:of:) throws` (atomic marker write).
  - `folder(of note: URL) -> String?` — the sidebar folder the file sits directly in.
  - Plain-English `MeetingFoldersError` (`LocalizedError`): empty/invalid name, name taken, missing folder.
  - All directory changes take `NoteIndex.withWriteLock`.
- `SeriesLibrary.folderSeries` ignores marker folders (a note in one gets its series from `series:` only).
- `MeetingSummary` gains `filedIn: String?` (sidebar folder name), filled in `SeriesLibrary.summaries`.
- `NoteIndex.relocateLocked`: when the note currently sits in a marker folder, the target folder is that folder,
  not the series folder (title/series changes keep it filed).
- Tests (`MeetingFoldersTests`, additions to `SeriesLibraryTests`, `NoteIndexTests`/`SeriesActionsTests`):
  create/list/rename/colour/name rules/clashes with series folders; a note in a marker folder keeps its frontmatter
  series and gets `filedIn`; retitle and `SeriesActions.move` keep a filed note in its folder; hand-made folder
  without marker still reads as series.

## Task 2 — LyraCore: moving notes and removing folders

- `FolderActions` (enum, like `SeriesActions`):
  - `move(_ loaded: LoadedNote, to folder: String?, index:) throws -> SeriesOutcome` — §4.3: writes `series:` first
    when the series came only from the folder (via `index.update`), then moves the file (new NoteIndex method
    `moveLocked`-style, under the lock, ` (n)` on clashes + link rewrite), then rewrites the series page if any.
    `nil` → where relocate would put it unfiled (series folder or root). No-op when already there.
  - `remove(_ folder: String, index:) throws -> [String]` — moves every Lyra note out (as `move(…, to: nil)`), then
    `trashItem`s the folder if only the marker is left, else leaves it and returns a plain-English problem.
- Tests: into, between, out (to series folder and to root), name clash adds ` (2)` and rewrites links, series kept
  when it came from the folder, series page rewritten, remove trashes only an empty folder, a foreign file blocks it,
  nothing deleted (files end up in Trash or moved — use a temp dir under the test's own folder and check
  `trashItem` was used by asserting the item is gone from its place and no `removeItem` exists in the code path).

## Task 3 — App: sidebar model, toggle and pages

- `Route.folder(String)`.
- `SidebarModel` (`@MainActor ObservableObject`, owned by `AppModel` or `MainWindow`): `visible` (persisted in
  `UserDefaults` key `sidebarVisible`, default false), `folders`, `notesByFolder: [String: [MeetingSummary]]`,
  `expanded: Set<String>`, `notice`. `refresh()` off the main actor (reads `MeetingFolders.all()` and summaries).
  `create`, `rename`, `setColour`, `remove`, and `move(noteID:to:)` which updates the lists at once
  (optimistic, animated) then runs `FolderActions.move` detached; on failure rolls back and sets `notice`.
  Refresh on `app.revision` and window-key like HomeModel.
- Views (new files, each small): `Sidebar.swift` (Home row, FOLDERS header with +, folder rows with chevron,
  count, expanded note rows, inline rename, context menu with Colour swatches and Remove folder… confirm),
  `FolderPage.swift` (serif title with coloured glyph, rows like home Recent, context menu: Remove from folder,
  Move to Trash), `SidebarToggle` pill in the title bar (`sidebar.left`), BackPill moved right of it.
- `MainWindow`: `HStack` of sidebar (width 240, slides with a spring, hairline divider) and the page; under
  760 pt wide it overlays. ⌘\ shortcut and a View menu item "Show Sidebar"/"Hide Sidebar" in `LyraCommands`
  (via a focused value or a shared object).
- `FolderColour` → SwiftUI `Color` mapping in the app target (muted, readable on #292929 and light).
- App tests: visibility persists, optimistic move then rollback on failure (inject the mover closure).

## Task 4 — App: drag and drop, debug launch, screenshots

- `MeetingDrag: Transferable` carrying the `lyra_id` (custom `UTType` exported as `au.aidos.lyra.meeting`,
  `CodableRepresentation`); `.draggable` on home rows, series card rows, folder page rows, sidebar note rows, with
  a capsule preview (title).
- `.dropDestination` on folder rows, Home row (= unfiled) and the folder page: `isTargeted` drives the colour
  highlight + `folder.fill`, spring animation; same-folder drop not highlighted. Spring-open after 0.7 s hover.
- Debug launch: `LYRA_DEBUG_SIDEBAR=1` opens it; `LYRA_DEBUG_FOLDER=<name>` shows that folder page;
  `LYRA_DEBUG_EXPAND=<name>` expands a folder in the sidebar; `LYRA_DEBUG_TARGET=<name>` shows that row in its
  drop-highlight state (for a screenshot of the highlight without dragging).
- Build with `scripts/build-app.sh` (debug env needs a debug build: follow how earlier screenshots were made, see
  `docs/notes/phase3-screens`), scratch copy of a few notes into a temp vault with two marker folders, screenshots
  via `screencapture -l <windowID>` of Lyra's own window only: sidebar open (one folder expanded), hidden,
  drop highlight, a folder page. Dark mode.
