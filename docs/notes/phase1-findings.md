# Phase 1 findings

## Task 4 — process tap (2026-10-27)

- **Muted output does not silence the tap.** With `muteBehavior = .unmuted` and system output
  muted, `afplay` of the 3-voice fixture recorded at peak ≈ 0.77, the same as unmuted
  (≈ 0.77). No tap option changes were needed.
- **No permission = silence, not an error.** The first xctest run produced the full 5.09 s of
  frames, all zeros (peak 0.0), for both the muted and unmuted runs. Every Core Audio call
  returned noErr. Later runs passed with no code change. The likely cause is that the Audio
  Capture (TCC) permission for the responsible app (Claude.app) was granted between runs, but
  this was not confirmed. **Lyra must treat a silent meeting track as a possible permission
  problem.** A `peakLevel` of 0 is the only signal.
- **A fresh process can miss a just-started app's process object.** In a freshly launched
  `Lyra.app`, `kAudioHardwarePropertyProcessObjectList` did not list `afplay` for about 2 s
  (8 retries × 200 ms after a 0.5 s wait). The second lookup in the same process found it at
  once. In the app, detection already polls Core Audio before recording starts, so the list is
  warm by then. If `start` fails with "no Core Audio process", retry briefly before warning.
- Capture format seen: 2 ch, 48 kHz, Float32. The CAF is stored interleaved (`afinfo` reads it
  fine). A CAF read mid-recording, without `stop()`, opens with `length > 0`.

## Task 5 — speech pipeline (2026-10-27)

FluidAudio 0.17.7, offline diarizer (default config) + Parakeet **Ultra** ASR, transcribing
each diarized turn on its own. Models live in `~/Library/Application Support/FluidAudio/Models`
(`speaker-diarization`, `parakeet-ultra`), outside the repo.

- **Speaker count on the 3-voice fixture: 2, not 3.** With the default config, Fred is not
  found as a separate speaker. His first line is split across Daniel (S1) and Flo (S2); his
  second line goes to Daniel. Daniel and Flo are always right. Default-run transcript:

  ```
  [meeting:S1] 0.00-6.11   Thanks for jumping on, everyone. Today we need to lock the shoot dates for the Coffee Roaster campaign.
  [meeting:S2] 8.34-12.60  I can do the second Saturday, but I need a gail list by Wednesday.
  [meeting:S1] 13.65-15.18 I can make Saturday.
  [meeting:S2] 15.99-18.52 and move it to the Friday afternoon instead.
  [meeting:S1] 19.17-24.26 Friday works for me. Flo, does Friday still give you enough time for the gear list?
  [meeting:S2] 25.13-29.37 Yes, Friday is fine. I'll send the list on Tuesday night.
  [meeting:S1] 31.36-35.14 I'll book the cafe for two o'clock and confirm with the owner.
  [meeting:S1] 35.72-42.19 Perfect. So Friday add 2, gear list Tuesday, and Fred confirms the venue. Thanks all.
  ```

- **Clustering threshold does not fix it.** `clusteringThreshold` (AHC cut distance; larger
  merges more): 0.6 (default) → 2, 0.5 → 2, 0.4 → 2, 0.3 → 2, 0.2 → 2 (different wrong split:
  Fred's lines go to Flo, Fred's second line split mid-sentence), 0.1 → **1**. Lower is not
  monotonically "more speakers" once VBx refines the clusters.
- **A known speaker count fixes it completely.** `clustering.numSpeakers = 3` gave 3 speakers
  and all 7 lines attributed correctly (Daniel S1, Fred S2, Flo S3), with Fred's first line
  whole: "I can make Saturday. Could we move it to the Friday afternoon instead?". Lyra does
  not use this yet (brief keeps the default). Candidate for later: pass the participant count
  when the meeting app or calendar knows it, or set `minSpeakers`.
- **Words between turns are lost.** Only diarized spans are transcribed. In the default run,
  "Could we" (≈15.2–16.0 s, between two turns) is missing from the transcript.
- **Per-turn ASR quality is good but short slices hurt.** "gear list" heard as "gail list" in
  a 4 s turn; "Friday at 2" as "Friday add 2"; "can't" as "can". The full-length turns are
  otherwise word-perfect. Not redesigned (per brief).
- **Runtime:** first run 124.5 s (both model downloads + Core ML compile). Warm run 1.6 s
  for the 43 s fixture, including model loads.
