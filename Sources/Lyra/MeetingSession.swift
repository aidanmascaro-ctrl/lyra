import Foundation
import LyraAudio
import LyraCore

/// One recording in progress: its reserved folder and note, `meeting.json`, the two-track recorder, and the
/// on-screen text read from the meeting app's window.
@MainActor
final class MeetingSession {
    private static let screenTextInterval: Duration = .seconds(60)
    private static let screenTextLimit = 200

    private(set) var meeting: Meeting
    let target: MicUser?
    let folder: URL
    let noteURL: URL
    private let recorder: TwoTrackRecorder
    private var screenReader: Task<Void, Never>?

    /// Reserves the folder, creates the note (so Aidan can type in it from the first second), writes `meeting.json`
    /// (so a crash can be recovered), then starts recording. A note that can't be made is no reason to lose the
    /// recording: processing makes it later. If the meeting app's audio can't be captured, records the mic alone
    /// and saves why in `meeting.json`.
    init(meeting: Meeting, target: MicUser?, paths: MeetingPaths) async throws {
        self.meeting = meeting
        self.target = target
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
            if let warning = try await recorder.start(in: folder) {
                self.meeting.warnings.append(warning)
                try? self.meeting.save(in: folder)  // stop() saves it again
            }
        } catch {
            // Nothing was recorded (and nothing typed yet): free the name.
            try? FileManager.default.removeItem(at: folder)
            if madeNote { try? FileManager.default.removeItem(at: noteURL) }
            throw error
        }
        if let target { readScreenText(pid: target.pid) }
    }

    /// Stops both tracks (CAFs are finalised) and saves the end time, track levels and screen text in `meeting.json`,
    /// so a meeting recovered on a later launch still gets its silent-track warning.
    func stop() async -> [TrackResult] {
        screenReader?.cancel()
        screenReader = nil
        let tracks = await recorder.stop()
        meeting.endedAt = Date()
        meeting.tracks = tracks
        try? meeting.save(in: folder)
        return tracks
    }

    /// Reads the meeting window's text now and every minute while recording; in memory until `stop` saves it.
    private func readScreenText(pid: pid_t) {
        screenReader = Task { [weak self] in
            while !Task.isCancelled {
                let lines = await ScreenText.read(pid: pid)
                guard !Task.isCancelled else { return }
                self?.keep(lines)
                try? await Task.sleep(for: Self.screenTextInterval)
            }
        }
    }

    /// Distinct lines in the order first seen, up to the limit.
    private func keep(_ lines: [String]) {
        var kept = meeting.screenText ?? []
        for line in lines where kept.count < Self.screenTextLimit && !kept.contains(line) { kept.append(line) }
        meeting.screenText = kept
    }
}
