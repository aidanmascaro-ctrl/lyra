# Plan — dividers and pictures in notes

Design: `docs/superpowers/specs/2026-11-10-lyra-note-blocks-design.md`. Each task: tests first, `swift test` green,
then a review pass before the next.

## Task 1 — the block model (LyraCore)
- `BlockKind` gains `.divider` and `.image`; `NoteBlock` gains `media: String?` — the line exactly as written
  (`***`, `---`, `![[x.png]]`, `![](a/x.png)`), so it round-trips untouched. Runs stay empty; `plainText` is "".
- `NoteMarkdown.parse`: a line that is exactly `***`, `---` or `___` (trailing spaces allowed) is a divider, except
  `---` straight under a text line (Obsidian reads that as a heading underline, so it stays text). A line that is
  only one image embed (`![[name.ext]]`, `![[name.ext|…]]`, `![alt](path.ext)`, image extensions only) is an image.
  `render` writes `media` back (`***` for a new divider).
- `NoteMarkdown.imageTarget(of:)`: the file path inside an embed (no `|size`, `%20` decoded).
- `NoteText`: an image/divider block is one U+FFFC character carrying the block keys plus `lyraMedia`;
  `NoteText.length(of:)` (1 for these, utf16 count otherwise) replaces `plainText.utf16.count` for offsets.
- `ExpandedMerge.unitRange`: unchanged (a picture at indent 0 owns nothing). `newNotes` already skips empty text.
- Tests: parse/render round trips, the `---`-under-text case, embeds with sizes/alt text, attributed round trip.

## Task 2 — picture files (LyraCore `Notes/NoteImages.swift`)
- `save(_ data: Data, ext: String, besideNote: URL, now: Date) -> String`: writes `Pasted image yyyyMMddHHmmss.ext`
  (` 1`, ` 2`… on a clash) atomically next to the note, never overwriting; returns the file name.
- `keepsOwnBytes(ext:)`: png/jpg/jpeg/gif/webp (else the app converts to PNG first).
- `resolve(_ target: String, note: URL, vaultRoot: URL) -> URL?`: beside the note, then the path from the note's
  folder, then from the vault root, then any non-hidden file with that name in the vault.
- `NoteIndex.moveLocked`: after moving a note, moves the pictures it embeds that sat beside it (bare file names
  only; skipped when the destination has one of that name).
- Tests in temp dirs.

## Task 3 — the editor (Lyra app)
- `NoteStyle`: attachment cells. Picture: drawn at its own size in points, scaled down to the column width; a grey
  box with the name when missing. Divider: a thin rule, full column width. Images loaded once per URL (cache).
- `NoteTextView`: Return on a picture/divider adds an empty line under it; typing on one goes on a new line;
  Backspace after one (or at the start of the line below) removes it; `***`/`---`/`___` + Return makes a divider;
  paste/drop of image data or image files saves via `NoteImages` and inserts picture blocks after the current
  (or dropped-at) block, replacing an empty line; dragging a picture itself drags its block; the handle shows on
  pictures and dividers. All through `replace(with:)`, so one undo step each.
- `NoteEditor` takes `noteURL`/`vaultRoot`; `MeetingPage` passes `model.loaded?.url` and `notes.vaultRoot`.
- Tests (`LyraAppTests`): Return/Backspace/typing around pictures and dividers, divider shortcut, paste of PNG
  data into a temp note folder.

## Task 4 — check and show
- `swift test`, `swift build -c release`; a debug build pointed at a scratch vault, screenshots via
  `screencapture -l` of Lyra's window only; send to Aidan; merge on his word via a temporary worktree.
