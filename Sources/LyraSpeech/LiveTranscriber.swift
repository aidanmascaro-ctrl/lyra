import AVFoundation
import FluidAudio
import Foundation
import LyraAudio
import LyraCore

/// A rough transcript of a meeting while it is recorded, for the live drawer. Reads each track's growing CAF
/// every second (the recorders are never touched) and streams it through its own FluidAudio sliding-window ASR.
/// `updates` yields `(track, text, isFinal)` for `LiveLines.apply`. A failure, or falling too far behind
/// (see `LiveHealth`), ends `updates` early; the recording carries on and the full transcript is still made
/// after the meeting.
public actor LiveTranscriber {
    private static let pollInterval: Duration = .seconds(1)
    private static let config = SlidingWindowAsrConfig.streaming.applying(language: .english)

    public nonisolated let updates: AsyncStream<(TrackKind, String, Bool)>
    private let continuation: AsyncStream<(TrackKind, String, Bool)>.Continuation
    private let folder: URL
    private let tracks: [TrackKind]
    private var managers: [(TrackKind, SlidingWindowAsrManager)] = []
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false
    private var health = LiveHealth(windowSeconds: config.chunkSeconds)

    /// `tracks` are the CAFs recording in `folder` (`mic.caf`, `meeting.caf`).
    public init(folder: URL, tracks: [TrackKind]) {
        self.folder = folder
        self.tracks = tracks
        (updates, continuation) = AsyncStream.makeStream()
    }

    /// Loads the same Parakeet model the after-meeting pass uses and starts one stream per track.
    /// On a throw everything started is released and `updates` has ended.
    public func start() async throws {
        do {
            let models = try await AsrModels.downloadAndLoad(version: .ultra)
            for track in tracks {
                try checkStopped()
                let manager = SlidingWindowAsrManager(config: Self.config)
                managers.append((track, manager))
                try await manager.loadModels(models)
                let windows = await manager.transcriptionUpdates
                try await manager.startStreaming(source: track == .mic ? .microphone : .system)
                try checkStopped()
                tasks.append(Task { [continuation] in
                    var tail = LiveTail()
                    for await window in windows {
                        self.windowDone(track)
                        for line in tail.receive(text: window.text, confirmed: window.isConfirmed) {
                            continuation.yield((track, line.text, line.isFinal))
                        }
                    }
                })
            }
            try checkStopped()
            tasks.append(Task { await self.poll() })
        } catch {
            await stop()
            throw error
        }
    }

    /// Ends `updates` and frees the models. Safe to call more than once, or during `start`.
    public func stop() async {
        stopped = true
        for task in tasks { task.cancel() }
        tasks = []
        // Popped one at a time: a `start` still running may add one while this awaits.
        while let (_, manager) = managers.popLast() { await manager.cleanup() }
        continuation.finish()
    }

    private func checkStopped() throws {
        if stopped { throw CancellationError() }
    }

    private func windowDone(_ track: TrackKind) {
        health.windowDone(track)
    }

    /// Feeds each track the frames written since the last poll. A failed read is retried next poll; live
    /// stops after too many in a row, or when the recogniser falls too far behind.
    private func poll() async {
        let feeds = managers.map { track, manager in
            (track, GrowingCAFReader(url: folder.appendingPathComponent("\(track.rawValue).caf")), manager)
        }
        while !Task.isCancelled {
            for (track, reader, manager) in feeds {
                do {
                    guard let frames = try reader.readNew() else { health.readSucceeded(track); continue }
                    let samples = try AudioLoader.mono16k(frames)
                    health.readSucceeded(track)
                    guard let samples else { continue }
                    health.fed(track, seconds: Double(samples.frameLength) / samples.format.sampleRate)
                    await manager.streamAudio(samples)
                } catch {
                    // A file can be briefly unreadable (e.g. while the recorder's writer flushes): try again.
                    if health.readFailed(track) { return await stop() }
                }
            }
            if feeds.contains(where: { health.isBehind($0.0) }) { return await stop() }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

/// When live text gives up: a track's file unreadable for several polls in a row, or a recogniser this far
/// behind the audio it has been fed (each window it finishes covers `windowSeconds` of new audio; in step it
/// trails by about one window plus its look-ahead). Either ends live text only; the recording carries on.
struct LiveHealth {
    static let maxConsecutiveReadFailures = 5
    static let maxBehindSeconds: Double = 30

    let windowSeconds: Double
    private var readFailures: [TrackKind: Int] = [:]
    private var fedSeconds: [TrackKind: Double] = [:]
    private var windows: [TrackKind: Int] = [:]

    init(windowSeconds: Double) {
        self.windowSeconds = windowSeconds
    }

    /// True when this failure is one too many in a row: time to give up.
    mutating func readFailed(_ track: TrackKind) -> Bool {
        readFailures[track, default: 0] += 1
        return readFailures[track, default: 0] >= Self.maxConsecutiveReadFailures
    }

    mutating func readSucceeded(_ track: TrackKind) {
        readFailures[track] = 0
    }

    mutating func fed(_ track: TrackKind, seconds: Double) {
        fedSeconds[track, default: 0] += seconds
    }

    mutating func windowDone(_ track: TrackKind) {
        windows[track, default: 0] += 1
    }

    func isBehind(_ track: TrackKind) -> Bool {
        fedSeconds[track, default: 0] - Double(windows[track, default: 0]) * windowSeconds > Self.maxBehindSeconds
    }
}

/// Turns FluidAudio's window updates into live lines, mirroring its two tiers: an unconfirmed window's text
/// is new audio, so it extends the open line; a confirmed window promotes the open line to final and its
/// own text opens the next one.
struct LiveTail {
    private var open = ""

    mutating func receive(text: String, confirmed: Bool) -> [(text: String, isFinal: Bool)] {
        let text = text.trimmingCharacters(in: .whitespaces)
        if confirmed {
            var lines: [(text: String, isFinal: Bool)] = open.isEmpty ? [] : [(open, true)]
            open = text
            if !open.isEmpty { lines.append((open, false)) }
            return lines
        }
        guard !text.isEmpty else { return [] }
        open = open.isEmpty ? text : open + " " + text
        return [(open, false)]
    }
}
