# Task 6 report

Built: Sources/LyraCore/Transcript/TranscriptMerger.swift, Sources/LyraCore/Output/NoteRenderer.swift (extra `timeZone: TimeZone = .current` param for determinism); tests TranscriptMergerTests (4), NoteRendererTests (2).

TDD: RED = `swift test --filter 'TranscriptMergerTests|NoteRendererTests'` -> build failed (types did not exist). GREEN = Merger "Executed 4 tests, with 0 failures"; Renderer "Executed 2 tests, with 0 failures"; full `swift test` "Executed 30 tests, with 0 failures", 0 warning/error lines.

Sample note (tz +08:00):
---
lyra_id: 11111111-2222-3333-4444-555555555555
date: 2027-01-15T16:00:00+08:00
app: "Zoom"
duration_min: 52
recordings: "file:///Users/x/Lyra%20Recordings/m1/"
tags: [meeting]
---
# Weekly sync

## Notes
<!-- lyra:notes:start -->
<!-- lyra:notes:end -->

## Transcript
<!-- lyra:transcript:start -->
**Speaker 1** [00:00:04] hi all
<!-- lyra:transcript:end -->

Self-review: ties meeting-before-mic via explicit comparator; labels keyed by raw id so meeting:0 and mic:0 never share a number. Warning callouts omitted when empty.
Concerns: recordings URL has trailing slash when the folder URL is a directory URL; app-name quotes escaped.
