import AVFoundation
import FluidAudio
import Foundation
import LyraAudio
import LyraCore

/// A rough transcript of a meeting while it is recorded, for the live drawer. Reads each track's growing CAF
/// every second (the recorders are never touched) and streams it through its own FluidAudio sliding-window ASR.
/// `updates` yields `(track, text, isFinal)` for `LiveLines.apply`. Any failure ends `updates` early; the
/// recording carries on and the full transcript is still made after the meeting.
public actor LiveTranscriber {
    private static let pollInterval: Duration = .seconds(1)

    public nonisolated let updates: AsyncStream<(TrackKind, String, Bool)>
    private let continuation: AsyncStream<(TrackKind, String, Bool)>.Continuation
    private let folder: URL
    private let tracks: [TrackKind]
    private var managers: [(TrackKind, SlidingWindowAsrManager)] = []
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false

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
                let manager = SlidingWindowAsrManager(config: SlidingWindowAsrConfig.streaming.applying(language: .english))
                managers.append((track, manager))
                try await manager.loadModels(models)
                let windows = await manager.transcriptionUpdates
                try await manager.startStreaming(source: track == .mic ? .microphone : .system)
                try checkStopped()
                tasks.append(Task { [continuation] in
                    var tail = LiveTail()
                    for await window in windows {
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

    /// Feeds each track the frames written since the last poll. A read or conversion failure stops live.
    private func poll() async {
        let feeds = managers.map { track, manager in
            (GrowingCAFReader(url: folder.appendingPathComponent("\(track.rawValue).caf")), manager)
        }
        while !Task.isCancelled {
            do {
                for (reader, manager) in feeds {
                    guard let frames = try reader.readNew(), let samples = try AudioLoader.mono16k(frames) else { continue }
                    await manager.streamAudio(samples)
                }
            } catch {
                await stop()
                return
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
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
