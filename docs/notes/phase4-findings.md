# Phase 4 findings: tile names and slides (2026-10-27)

Measured while building `feat/phase-4-screen`. Design: `docs/superpowers/specs/2026-10-27-lyra-phase-4-screen-design.md`.

## Lit-tile ring
- Lyra has no colour list. A lit tile is any closed, thin, hollow ring of one saturated hue. Unit tests
  cover Zoom green, Teams purple and Discord green. Real Vision on drawn frames covers green and Meet blue.
- **Saturation floor is 0.35, not 0.45.** Meet's light blue `#8AB4F8` has a saturation of 0.44, so a 0.45
  floor missed it. Grey and white outlines (saturation 0) still don't count.
- The ring is looked for on a copy 960 px wide. A 3 pt border captured at 2× still shows clearly after it
  is blended into the dark background.
- **Not yet seen in a real call:** whether each app really draws a ring in the layout Aidan uses. Zoom's
  speaker view and FaceTime don't, and give no names (by design).

## Capture
- `CallWindow.frame` looks at windows owned by the meeting app (Chrome for its audio helper) **and** by
  the process itself. An `xctest` run started from the Claude app reports its owning app as Claude. Before
  this fix, the gated capture test picked the Claude window, the largest one with no call title. The frame
  stayed in the scratchpad and was deleted. Real recordings were never affected: their owner is the
  meeting app.
- The gated test (`LYRA_INTEGRATION=1`, Screen Recording granted) shows a drawn call in its own window,
  captures it through ScreenCaptureKit and reads "Marco Diaz" off the lit tile.

## Slides
- A 64-bit difference hash on a 64×36 thumbnail was dropped. Two slides from one template were only 3 bits
  apart, under the 6-bit duplicate line, so the second slide would have been lost. The build compares a
  160×90 thumbnail block by block instead (20×10 grid). It leaves out blocks that changed in 4 of the last
  8 seconds, which is webcam video.
- Real Vision on drawn frames: the gallery is rejected (only names to read). Each of two slides is saved
  once, and flipping back to the first saves nothing.

## End to end on a scratch copy
- Recording: 25 s cut from the 3-voice fixture (Daniel and Flo only), as `meeting.caf`, with a tile name
  for every second and 3 slides. Lyra's crash recovery processed it, with scratch notes, recordings and
  `LYRA_PEOPLE_FILE`.
- Result: 4 lines. Daniel Brooks and Flo Jones were both named *on screen* at confidence 1.0, and each was
  learned into the scratch people file (1 sample each). The note's jump line ends
  ` · [3 slides](file:///…/slides/)` with `slides: 3` in the frontmatter. Claude's Expanded uses the names.
- Fred was left out on purpose. The diarizer merges him into Daniel's or Flo's cluster (phase 1 finding).
  Worked out by hand from the script, not run: the votes would split about 70/30, under the 75% line, so
  those voices would stay "Speaker N". That is the intended outcome for a merged voice.
