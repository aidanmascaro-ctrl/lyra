# Phase 3 findings

## Task 10 — reading a CAF while it is still being recorded (2026-10-27)

**Question.** Can the live transcript read frames from `mic.caf` / `meeting.caf` while
`CAFWriter` is still writing them with `ExtAudioFileWriteAsync`, or does it need a copy taken
from the recorders' audio callback?

**Answer: yes, it can read the growing file.** `GrowingCAFReader` is used; the recorders
(`CAFWriter`, `MicRecorder`, `AppAudioRecorder`) are unchanged and the side-sink / ring-buffer
fallback was not needed.

Evidence, `LYRA_INTEGRATION=1 swift test --filter LiveTranscriptTests`
(`testReadsFramesWhileFileIsBeingWritten`): a `CAFWriter` fed a 440 Hz stereo tone at 48 kHz in
4096-frame buffers at real-time pace, from another thread, never closed while read.

- Reopening the file with `AVAudioFile(forReading:)` sees a `length` that grows: read after 1 s =
  49,152 frames, read 1 s later = 32,768 new frames (94,208 written by then).
- The frames are the real samples (peak ≈ 0.5), not zeros.
- The async writer reaches disk in 16,384-frame blocks (≈ 0.34 s at 48 kHz), so the reader runs
  up to about a third of a second behind the recording. Irrelevant for a 1 s poll.
- An open `AVAudioFile` does not see new frames; the reader must reopen each time (a CAF being
  written has no final length in its header).
- Reading alongside the writer costs the recording nothing: after `finish`, the closed file holds
  exactly the frames written and the writer reports no error.

**Live ASR.** FluidAudio's `SlidingWindowAsrManager` (`.streaming` config, English) with the same
Parakeet Ultra models as the after-meeting pass. Its windows are 11 s of new audio plus 2 s
context each side, so the first live text appears ~13 s into speech and then about every 11 s.
Fed 16 kHz mono (channels averaged, as `AudioLoader` does — FluidAudio's own converter would keep
only the left channel). The fixture streamed at 5x real time gave its words back
(`testLiveTranscribesFixtureSpeech`: "…the second Saturday… gear list by Wednesday… Friday
afternoon…").
