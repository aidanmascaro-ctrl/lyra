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
    /// If the meeting app's audio can't be captured, records the mic alone and saves why in `meeting.json`.
    init(meeting: Meeting, target: MicUser?, paths: MeetingPaths) async throws {
        self.meeting = meeting
        self.target = target
        (folder, noteURL) = try paths.reserve(for: meeting, timeZone: .current)
        recorder = TwoTrackRecorder(target: target)
        do {
            try meeting.save(in: folder)
            if let warning = try await recorder.start(in: folder) {
                self.meeting.warnings.append(warning)
                try? self.meeting.save(in: folder)  // stop() saves it again
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)  // nothing was recorded; free the name
            throw error
        }
    }

    /// Stops both tracks (CAFs are finalised) and saves the end time and track levels in `meeting.json`,
    /// so a meeting recovered on a later launch still gets its silent-track warning.
    func stop() async -> [TrackResult] {
        let tracks = await recorder.stop()
        meeting.endedAt = Date()
        meeting.tracks = tracks
        try? meeting.save(in: folder)
        return tracks
    }
}
