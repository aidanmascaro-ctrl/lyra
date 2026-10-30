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
  track's. Fixed in fix round 1, see below.
- **Fixture, Daniel enrolled:** lines in Daniel's sentences (0–6.8 s, 18.9–24.6 s) are named
  Daniel at 0.866. Flo's lines stay "Speaker 1". Fred's "I can make Saturday" (13.4–14.8 s) is
  **named Daniel**, and his closing line is joined with Daniel's last line (30.2–42.0 s, one
  line already in the track transcriber). The cause is the Phase 1 diarizer merge: Fred's
  turns are inside Daniel's cluster, so they carry Daniel's fingerprint. The integration test
  asserts Daniel's and Flo's lines and leaves Fred unasserted until Lyra passes a speaker
  count to the diarizer.

### Fix round 1 — voice-based echo removal (2026-10-27)

`TranscriptMerger.dropVoiceEcho` runs after the text echo filter and before naming. It drops
every mic cluster, with all its lines, when that cluster scores ≥ `voiceEchoSimilarity` = **0.75**
against any call-track cluster. A mic cluster that matches the owner (`isOwner`) is never dropped; any other known person who sounds like the call is dropped (fix round 2).
Why 0.75: the leak scored 0.852 against the call; different voices scored ≤ 0.243.

Re-run on 0409 with Aidan and Daniel enrolled (temp store), using the processor's order as
pure calls (nothing written beside the recording):

| Step | 0409 mic:S1 (leak) | 0409 mic:S2 (Aidan) |
| --- | --- | --- |
| Lines from the track transcriber | 6 | 4 |
| After the text echo filter | 6 kept | 4 kept |
| Max similarity to a call cluster | 0.852 | -0.013 |
| After the voice echo pass | **dropped** (lines and cluster) | kept |
| After naming | — | 4 lines, all "Aidan" |

The final transcript's mic track carries one label only: "Aidan".

### Fix round 3 — a weaker leak got through (2026-10-30)

A 29-minute Google Meet call (Aidan + one client, speakers not headphones) came out with three speakers.
The mic track split into Aidan and the client's voice leaking through the speakers. The text echo filter
dropped all but one of the leak's lines, but the leak scored only **0.678** against the call's cluster, under
the 0.75 voice-echo threshold, so it kept its cluster and its one line ("Speaker 1").

| Mic cluster | Speech | vs call cluster | vs Aidan (1 sample) |
| --- | --- | --- | --- |
| mic:S1 (Aidan) | 556 s | 0.038 | 0.544 |
| mic:S2 (the leak) | 832 s | **0.678** | -0.017 |

`voiceEchoSimilarity` is now **0.5**: below this leak, and well above the highest different-voice score
seen (0.245, today's call voice vs an enrolled stranger). Leaks vary with volume and room, so 0.85 was not typical.

Aidan's own cluster scored 0.544 against his single enrolled sample, under the 0.60 naming floor, so he showed
as "Speaker 2". Renaming him in that meeting adds a sample; no threshold change for naming.
