import Foundation
import LyraCore

/// Records the meeting app (when there is one) and the mic as separate CAF files in one folder.
/// `target == nil` is an in-person meeting: mic only.
public final class TwoTrackRecorder {
    private let target: MicUser?
    private var recorders: [TrackRecorder] = []

    public init(target: MicUser?) { self.target = target }

    /// Writes `meeting.caf` and `mic.caf`. If any track fails to start, none keep running.
    public func start(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tracks: [(TrackKind, TrackRecorder)] = [(.mic, MicRecorder())]
        if let target { tracks.insert((.meeting, AppAudioRecorder(target: target)), at: 0) }
        var started: [TrackRecorder] = []
        for (kind, recorder) in tracks {
            try recorder.start(writingTo: folder.appendingPathComponent("\(kind.rawValue).caf"))
            started.append(recorder) // on throw, already-started recorders are released and tear down in deinit
        }
        recorders = started
    }

    /// Runs on the caller's actor, so a @MainActor owner can await it without sending the recorder.
    nonisolated(nonsending) public func stop() async -> [TrackResult] {
        var results: [TrackResult] = []
        for recorder in recorders { results.append(await recorder.stop()) }
        recorders = []
        return results
    }
}
