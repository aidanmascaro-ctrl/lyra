import Foundation
import LyraCore

/// Records the meeting app (when there is one) and the mic as separate CAF files in one folder.
/// `target == nil` is an in-person meeting: mic only.
public final class TwoTrackRecorder {
    static let meetingAttempts = 12

    private let target: MicUser?
    private let makeMeeting: (MicUser) -> TrackRecorder
    private let makeMic: () -> TrackRecorder
    private let retryDelay: Duration
    private var recorders: [TrackRecorder] = []

    public convenience init(target: MicUser?) {
        self.init(target: target, meeting: AppAudioRecorder.init, mic: MicRecorder.init)
    }

    init(target: MicUser?, meeting: @escaping (MicUser) -> TrackRecorder, mic: @escaping () -> TrackRecorder,
         retryDelay: Duration = .milliseconds(250)) {
        self.target = target
        self.makeMeeting = meeting
        self.makeMic = mic
        self.retryDelay = retryDelay
    }

    /// Writes `meeting.caf` and `mic.caf`. The meeting track is best-effort: the app's Core Audio process
    /// object can take ~2 s to appear, so it is retried for ~3 s; if it still won't start, only the mic
    /// records and the returned warning says why. Throws (with nothing left running) only if the mic fails.
    nonisolated(nonsending) public func start(in folder: URL) async throws -> String? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var started: [TrackRecorder] = []
        var warning: String?
        if let target {
            let url = folder.appendingPathComponent("\(TrackKind.meeting.rawValue).caf")
            for attempt in 1...Self.meetingAttempts {
                let recorder = makeMeeting(target)
                do {
                    try recorder.start(writingTo: url)
                    started.append(recorder)
                    break
                } catch where attempt < Self.meetingAttempts {
                    try await Task.sleep(for: retryDelay)
                } catch {
                    try? FileManager.default.removeItem(at: url)  // a half-opened file must not pass for a recording
                    warning = "Couldn't capture \(target.appName) audio: \(error). Transcript is from your microphone only."
                }
            }
        }
        let mic = makeMic()
        // On throw, a started meeting recorder is released and tears down in deinit.
        try mic.start(writingTo: folder.appendingPathComponent("\(TrackKind.mic.rawValue).caf"))
        recorders = started + [mic]
        return warning
    }

    /// Both tracks stop capturing together, so they stay lined up once resumed. Every track is asked even if one
    /// fails; the first failure is thrown, since that track may still be capturing.
    public func pause() throws {
        var failure: Error?
        for recorder in recorders {
            do { try recorder.pause() } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Restarts both tracks in the same files. A meeting track that won't restart is a warning (the mic carries
    /// on alone, as at start); a mic that won't restart throws.
    public func resume() throws -> String? {
        var warning: String?
        for recorder in recorders {
            do { try recorder.resume() } catch where recorder !== recorders.last {
                warning = "Couldn't capture \(target?.appName ?? "the meeting") audio after resuming: \(error). Transcript after that is from your microphone only."
            }
        }
        return warning
    }

    /// Runs on the caller's actor, so a @MainActor owner can await it without sending the recorder.
    /// Each result carries its `startOffset`: the tracks start up to ~3 s apart.
    nonisolated(nonsending) public func stop() async -> [TrackResult] {
        var results: [TrackResult] = []
        for recorder in recorders { results.append(await recorder.stop()) }
        recorders = []
        return TrackResult.withStartOffsets(results)
    }
}
