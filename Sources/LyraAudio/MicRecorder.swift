import AVFoundation
import LyraCore

/// Records the default input device via AVAudioEngine to a CAF in the input's native format.
public final class MicRecorder: TrackRecorder {
    private let engine = AVAudioEngine()
    private var writer: CAFWriter?

    public init() {}

    public func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError(description: "no microphone input available") }
        let writer = try CAFWriter(url: url, format: format.streamDescription.pointee)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in writer.write(buffer.audioBufferList) }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = writer.finish(kind: .mic)
            throw error
        }
        self.writer = writer
    }

    public func stop() async -> TrackResult {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        guard let writer else {
            return TrackResult(kind: .mic, url: URL(fileURLWithPath: "/dev/null"), seconds: 0, peakLevel: 0, error: "not recording")
        }
        self.writer = nil
        return writer.finish(kind: .mic)
    }

    deinit {
        guard let writer else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        _ = writer.finish(kind: .mic)
    }
}
