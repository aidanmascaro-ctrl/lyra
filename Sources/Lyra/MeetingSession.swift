import Foundation
import LyraAudio
import LyraCore
import LyraSpeech

/// One recording in progress: its reserved folder and note, `meeting.json`, the two-track recorder, the
/// on-screen text read from the meeting app's window, and the rough live transcript.
@MainActor
final class MeetingSession {
    private static let screenTextInterval: Duration = .seconds(60)
    private static let screenTextLimit = 200
    static let liveStoppedMessage = "Live transcript stopped — the full transcript will still be made after the meeting."

    private(set) var meeting: Meeting
    let target: MicUser?
    let folder: URL
    let noteURL: URL
    private let recorder: TwoTrackRecorder
    private(set) var isPaused = false
    private var screenReader: Task<Void, Never>?
    private var live: LiveTranscriber?
    private var liveReader: Task<Void, Never>?
    private var liveLines = LiveLines()
    private let onLive: @MainActor (_ lines: [LiveLine], _ error: String?) -> Void

    /// Reserves the folder, creates the note (so Aidan can type in it from the first second), writes `meeting.json`
    /// (so a crash can be recovered), then starts recording. A note that can't be made is no reason to lose the
    /// recording: processing makes it later. If the meeting app's audio can't be captured, records the mic alone
    /// and saves why in `meeting.json`. `onLive` gets the live transcript as it changes, and the reason if it stops.
    init(meeting: Meeting, target: MicUser?, paths: MeetingPaths,
         onLive: @escaping @MainActor (_ lines: [LiveLine], _ error: String?) -> Void) async throws {
        self.meeting = meeting
        self.target = target
        self.onLive = onLive
        (folder, noteURL) = try paths.reserve(for: meeting, timeZone: .current)
        recorder = TwoTrackRecorder(target: target)
        var madeNote = false
        do {
            try MeetingProcessor.createSkeletonNote(for: meeting, recordingsFolder: folder, at: noteURL)
            self.meeting.notePath = noteURL.path
            madeNote = true
        } catch {
            self.meeting.warnings.append("Lyra couldn't create this meeting's note when recording started, so it was made after the meeting instead. (\(error.localizedDescription))")
        }
        do {
            try self.meeting.save(in: folder)
            try await startRecorder()
        } catch {
            // Nothing was recorded (and nothing typed yet): free the name.
            try? FileManager.default.removeItem(at: folder)
            if madeNote { try? FileManager.default.removeItem(at: noteURL) }
            throw error
        }
        if let target { readScreenText(pid: target.pid) }
        transcribeLive()
    }

    /// Records into a note that already exists — one New note made, or one ended and written up — keeping its
    /// folder, note and meeting.json. A written-up part is filed under parts/ first, and joined back on when this
    /// part is written up. If recording can't start, the note is left exactly as it was.
    init(recordingInto folder: URL, noteURL: URL, meeting: Meeting,
         onLive: @escaping @MainActor (_ lines: [LiveLine], _ error: String?) -> Void) async throws {
        var meeting = meeting
        var previous: Meeting?
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path) {
            previous = try RecordingParts.archive(folder: folder)
            meeting = try Meeting.load(from: folder)
        }
        meeting.recordingStartedAt = Date()
        self.meeting = meeting
        self.target = nil
        self.onLive = onLive
        self.folder = folder
        self.noteURL = noteURL
        recorder = TwoTrackRecorder(target: nil)
        do { try await startRecorder() } catch {
            // A half-opened file would make crash recovery treat this note as a recording.
            for kind in [TrackKind.mic, .meeting] { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(kind.rawValue).caf")) }
            if let previous {
                do { try RecordingParts.restore(folder: folder, previous: previous) } catch let restoreError {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                        "\(error.localizedDescription) The earlier recording is filed under “parts” in the recording folder and couldn't be put back: \(restoreError.localizedDescription)"])
                }
            }
            throw error
        }
        transcribeLive()
    }

    private func startRecorder() async throws {
        try meeting.save(in: folder)  // with recordingStartedAt, before any audio, so a crash knows when it began
        if let warning = try await recorder.start(in: folder) {
            meeting.warnings.append(warning)
            try? meeting.save(in: folder)  // stop() saves it again
        }
    }

    /// How loud the meeting is now; nothing while paused.
    var level: Float { isPaused ? 0 : recorder.level }

    /// Lets go of the mic and the call audio; nothing is recorded or read off the screen until `resume`.
    /// Throws if a track couldn't be let go of — it may still be capturing.
    func pause() throws {
        guard !isPaused else { return }
        isPaused = true
        try recorder.pause()
    }

    /// Carries on in the same files. Throws only if the mic won't restart; a call track that won't is a warning.
    func resume() throws {
        guard isPaused else { return }
        if let warning = try recorder.resume() {
            meeting.warn(warning)
            try? meeting.save(in: folder)
        }
        isPaused = false
    }

    /// Stops both tracks (CAFs are finalised) and saves the end time, track levels and screen text in `meeting.json`,
    /// so a meeting recovered on a later launch still gets its silent-track warning.
    /// Live transcription is let go of after the recording is safely closed, and before processing starts.
    func stop() async -> [TrackResult] {
        screenReader?.cancel()
        screenReader = nil
        liveReader?.cancel()
        liveReader = nil
        let tracks = await recorder.stop()
        await live?.stop()
        live = nil
        meeting.endedAt = Date()
        meeting.tracks = tracks
        try? meeting.save(in: folder)
        return tracks
    }

    /// Reads the meeting window's text now and every minute while recording; in memory until `stop` saves it.
    private func readScreenText(pid: pid_t) {
        screenReader = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isPaused == false {
                    let lines = await ScreenText.read(pid: pid, startTitle: self?.meeting.title ?? "")
                    guard !Task.isCancelled else { return }
                    self?.keep(lines)
                }
                try? await Task.sleep(for: Self.screenTextInterval)
            }
        }
    }

    /// Transcribes the tracks that are recording, from their growing files; started only once recording runs.
    /// A failure here ends live text only (the drawer says so): the recording is never touched.
    private func transcribeLive() {
        let tracks = [TrackKind.mic, .meeting].filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0.rawValue).caf").path)
        }
        let live = LiveTranscriber(folder: folder, tracks: tracks)
        self.live = live
        liveReader = Task { [weak self] in
            do {
                try await live.start()
                for await (track, text, isFinal) in live.updates { self?.showLive(track: track, text: text, isFinal: isFinal) }
            } catch {
                // Couldn't start (models, files): handled with every other early end, just below.
            }
            // Cancelled means `stop` ended it; anything else is live transcription giving up mid-meeting.
            guard !Task.isCancelled, let self else { return }
            onLive(liveLines.lines, Self.liveStoppedMessage)
        }
    }

    private func showLive(track: TrackKind, text: String, isFinal: Bool) {
        liveLines.apply(track: track, text: text, isFinal: isFinal)
        onLive(liveLines.lines, nil)
    }

    /// Distinct lines in the order first seen, up to the limit.
    private func keep(_ lines: [String]) {
        var kept = meeting.screenText ?? []
        for line in lines where kept.count < Self.screenTextLimit && !kept.contains(line) { kept.append(line) }
        meeting.screenText = kept
    }
}
