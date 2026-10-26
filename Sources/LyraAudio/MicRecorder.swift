import AVFoundation
import LyraCore

/// Records the default input device via AVAudioEngine to a CAF in the input's native format.
/// Survives input changes (device switch, Bluetooth call mode): the engine is restarted and the
/// new input is converted into the file's original format.
public final class MicRecorder: TrackRecorder {
    var session: MicSession?

    public init() {}

    public func start(writingTo url: URL) throws {
        guard session == nil else { throw AudioError(description: "mic recorder already started") }
        let session = try MicSession(url: url)
        do { try session.start() } catch {
            _ = session.finish()
            throw error
        }
        self.session = session
    }

    public func stop() async -> TrackResult {
        guard let session else {
            return TrackResult(kind: .mic, url: URL(fileURLWithPath: "/dev/null"), seconds: 0, peakLevel: 0, error: "not recording")
        }
        self.session = nil
        return session.finish()
    }

    deinit { _ = session?.finish() }
}

/// One mic recording. Engine reconfiguration happens under `lock`; tap blocks only touch the
/// Sendable writer or their own bridge.
final class MicSession: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let writer: CAFWriter
    private let fileFormat: AVAudioFormat
    private let lock = NSRecursiveLock() // a change notification posted from inside start/stop must not deadlock
    private var finished = false
    private var resumeError: String?
    private var bridge: FormatBridge?
    private var observer: NSObjectProtocol?

    init(url: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError(description: "no microphone input available") }
        writer = try CAFWriter(url: url, format: format.streamDescription.pointee)
        fileFormat = format
    }

    func start() throws {
        try lock.withLock { try installTapAndStart() }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.resume()
        }
    }

    /// The engine has stopped itself; restart it on the (possibly different) new input.
    private func resume() {
        lock.withLock {
            guard !finished else { return }
            do { try installTapAndStart() } catch where resumeError == nil {
                resumeError = "Microphone input changed at t=\(String(format: "%.1f", writer.seconds))s and could not be resumed: \(error)"
            } catch {}
        }
    }

    private func installTapAndStart() throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        bridge?.flush()
        bridge = nil
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError(description: "no microphone input available") }
        if format == fileFormat {
            let writer = writer
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in writer.write(buffer.audioBufferList) }
        } else {
            let bridge = try FormatBridge(from: format, to: fileFormat, writer: writer)
            self.bridge = bridge
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in bridge.write(buffer) }
        }
        engine.prepare()
        try engine.start()
    }

    func finish() -> TrackResult {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        let error = lock.withLock {
            finished = true
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            bridge?.flush()
            bridge = nil
            return resumeError
        }
        return writer.finish(kind: .mic, extraError: error)
    }
}

/// Converts tap buffers in a new input format into the file's format. The converter and output
/// buffer are built once, off the audio path. Tap blocks run serially on AVAudioEngine's tap
/// thread (not the real-time IO thread); each `write` reuses the same output buffer.
final class FormatBridge: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private let writer: CAFWriter

    init(from: AVAudioFormat, to: AVAudioFormat, writer: CAFWriter) throws {
        guard let converter = AVAudioConverter(from: from, to: to),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 8192) else {
            throw AudioError(description: "cannot convert mic input \(from) to \(to)")
        }
        self.converter = converter
        self.output = output
        self.writer = writer
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        var supplied = false
        convert { inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
    }

    /// Writes the samples the converter still holds. Call once, after the tap is removed.
    func flush() {
        convert { inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
    }

    private func convert(_ input: (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) {
        withoutActuallyEscaping(input) { input in
            var status: AVAudioConverterOutputStatus
            repeat { // loops while the converter has more output than one buffer holds
                output.frameLength = 0
                status = converter.convert(to: output, error: nil) { _, inputStatus in input(inputStatus) }
                if output.frameLength > 0 { writer.write(output.audioBufferList) }
            } while status == .haveData
        }
    }
}
