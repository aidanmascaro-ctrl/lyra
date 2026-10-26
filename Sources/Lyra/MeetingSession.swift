import Foundation
import LyraAudio
import LyraCore

/// One recording in progress: its reserved folder and note path, `meeting.json`, and the two-track recorder.
@MainActor
final class MeetingSession {
    private(set) var meeting: Meeting
    let target: MicUser?
    let folder: URL
    let noteURL: URL
    private let recorder: TwoTrackRecorder

    /// Reserves the folder, writes `meeting.json` (so a crash can be recovered), then starts recording.
    /// Retries for ~3 s: the meeting app's Core Audio process object can take ~2 s to appear.
    init(meeting: Meeting, target: MicUser?, paths: MeetingPaths) async throws {
        self.meeting = meeting
        self.target = target
        (folder, noteURL) = try paths.reserve(for: meeting, timeZone: .current)
        recorder = TwoTrackRecorder(target: target)
        do {
            try meeting.save(in: folder)
            var attempt = 0
            while true {
                do { try recorder.start(in: folder); break } catch {
                    attempt += 1
                    guard attempt < 12 else { throw error }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)  // nothing was recorded; free the name
            throw error
        }
    }

    /// Stops both tracks (CAFs are finalised) and records the end time in `meeting.json`.
    func stop() async -> [TrackResult] {
        let tracks = await recorder.stop()
        meeting.endedAt = Date()
        try? meeting.save(in: folder)
        return tracks
    }
}
