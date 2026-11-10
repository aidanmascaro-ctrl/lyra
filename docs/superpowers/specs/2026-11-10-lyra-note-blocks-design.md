# Lyra — dividers and pictures in notes

**Status:** approved by Aidan, 10 Nov 2026. Choices made with him: picture files sit **right beside the note**;
pictures show at **their own size, shrunk only if wider than the text column**.

## What it adds

The My notes editor already has bullets, Tab / ⇧Tab to nest and un-nest them (three levels), and a drag handle
on every line. This adds two new kinds of line, Apple Notes / Notion style:

1. **Divider** — a thin rule across the column. Type `***` or `---` on an empty line and press Return.
2. **Picture** — paste (⌘V) or drag in an image or an image file. It becomes its own line: never inside text, never
   floating. Its drag handle (or dragging the picture itself) moves it up and down like any other line.

Both work in Expanded too, since it is the same editor. Claude never writes them.

## In the file (what Obsidian sees)

- Divider: a line `***` (Markdown's rule; unlike `---` it can never turn the line above into a heading). A `---`
  or `___` line Aidan types in Obsidian also reads as a divider, and is written back exactly as he typed it.
- Picture: the file is saved beside the note as `Pasted image 20261110143012.png` (Obsidian's own naming; a number
  is added if the name is taken; nothing is ever overwritten). The note gets a line `![[Pasted image 20261110143012.png]]`,
  which Obsidian shows as the picture. A picture line written in Obsidian (`![[x.jpg]]`, `![[x.png|300]]`,
  `![](path/x.png)`) shows in Lyra and is written back unchanged.
- PNG, JPEG, GIF and WebP keep their own bytes; anything else (a screenshot on the clipboard as TIFF, a HEIC photo)
  is saved as PNG, so Obsidian can show it.

## Finding a picture

Lyra looks beside the note first, then at the path as written (from the note, then from the vault root), then
anywhere in the vault by file name, as Obsidian does. Not found: a quiet grey box with the file name, and the line
is kept as is.

## When the note moves

When Lyra moves a note (series confirmed, renamed into a series), the pictures it embeds that sit beside it move
with it, unless a file of that name is already there. Obsidian finds them by name either way, so nothing breaks.

## Editing rules

- Return on a picture or divider starts a new empty line under it. Typing while one is selected starts a new line.
- Backspace just after a picture or divider (or at the start of the line below it) removes it. ⌘Z brings it back.
- Removing a picture line never deletes the picture file (nothing is permanently deleted).
- Pasting text works as before. A picture is never put inside a line of text: it goes on its own line, after the
  line the cursor is in (or in place of an empty line).

## Not doing

Resizing pictures in Lyra, captions, side-by-side pictures, other files (PDFs), checkboxes, tables.
