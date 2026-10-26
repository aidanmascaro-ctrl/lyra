# Phase 2 findings

## Task 4 — naming known voices, threshold calibration (2026-10-27)

Cosine similarity between a cluster's centroid and a person's prototype (both unit vectors, the
FluidAudio offline diarizer's default config). Produced by
`LYRA_INTEGRATION=1 LYRA_CALIBRATION=1 swift test --filter PeopleIntegrationTests`. All stores
were temp files. Aidan's recordings were only read. Only numbers and cluster ids are recorded
here, no transcript text.

**Enrolment.** "Aidan" is the 0405 mic track's longest cluster (`mic:S1`, 24.1 s; the only
cluster on that track). "Daniel" is the longest cluster of a fresh `say -v Daniel` clip with
none of the fixture's sentences, made at test time.

| Recording | Cluster | Speech | Who it is | vs Aidan | vs Daniel | Match |
| --- | --- | --- | --- | --- | --- | --- |
| 0405 | mic:S1 | 24.1 s | Aidan (enrolment source) | 1.000 | 0.102 | Aidan |
| 0405 | meeting | — | no clusters (no speech found on the call track) | — | — | — |
| 0409 | mic:S2 | 22.8 s | Aidan | **0.858** | -0.005 | Aidan |
| 0409 | mic:S1 | 16.8 s | **the video, leaking into the mic** (see below) | 0.005 | -0.054 | none |
| 0409 | meeting:S1 | 32.6 s | video narrator | -0.101 | -0.095 | none |
| fixture | meeting:S1 | 22.7 s | Daniel + Fred (diarizer merge) | 0.243 | **0.866** | Daniel |
| fixture | meeting:S2 | 10.7 s | Flo | -0.130 | 0.114 | none |

- **Same voice: 0.858–0.866** (Aidan across two meetings; Daniel enrolment clip vs fixture,
  even with Fred mixed into that cluster). **Different voice: -0.130 to 0.243.**
- **`MatchPolicy` unchanged (minSimilarity 0.60, minMargin 0.10).** The 0.60 floor sits about
  0.25 below the lowest same-voice score and 0.36 above the highest different-voice score.
  Every cluster was matched correctly. Moving the floor would not change any result here.
  With only 2 non-trivial same-voice pairs, this is a sanity check, not a tuned value.
  Revisit when real enrolments exist (Task 5 onwards).
- **0409's two mic clusters are not Aidan split in two.** `mic:S1` scores 0.852 against the
  call's own cluster (`meeting:S1`) and 0.005 against Aidan. It is the video playing through
  the speakers into the mic. **It gets past the echo filter** (all 6 of its lines are kept), so
  without naming it shows as an extra "Speaker N" on the mic track. The echo filter matches
  text, and the mic's transcript of the leaked audio evidently differs too much from the call
  track's. With Aidan enrolled, his real mic cluster is named, and the leak stays an unnamed
  speaker. A voice check (mic cluster ≥ ~0.8 against a call cluster → echo) would catch it;
  not done here, it is the merger's job.
- **Fixture, Daniel enrolled:** lines in Daniel's sentences (0–6.8 s, 18.9–24.6 s) are named
  Daniel at 0.866. Flo's lines stay "Speaker 1". Fred's "I can make Saturday" (13.4–14.8 s) is
  **named Daniel**, and his closing line is joined with Daniel's last line (30.2–42.0 s, one
  line already in the track transcriber). The cause is the Phase 1 diarizer merge: Fred's
  turns are inside Daniel's cluster, so they carry Daniel's fingerprint. The integration test
  asserts Daniel's and Flo's lines and leaves Fred unasserted until Lyra passes a speaker
  count to the diarizer.
