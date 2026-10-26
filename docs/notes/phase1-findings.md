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
