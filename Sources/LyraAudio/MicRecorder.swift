import AVFoundation
import LyraCore

/// Records the default input device via AVAudioEngine to a CAF in the input's native format — or, when the default
/// is a Bluetooth headset, the Mac's own mic (`MicChoice`, `DeviceMicSession`), so the headset stays out of call mode.
/// Survives input changes (device switch, Bluetooth call mode): the engine is restarted and the
/// new input is converted into the file's original format.
public final class MicRecorder: TrackRecorder {
    var session: MicSession?
    var deviceSession: DeviceMicSession?

    public init() {}

    public func start(writingTo url: URL) throws {
        guard session == nil, deviceSession == nil else { throw AudioError(description: "mic recorder already started") }
        if let device = AudioInputs.chosenCaptureDevice() {
            let session = try DeviceMicSession(url: url, device: device)
            do { try session.start() } catch {
                _ = session.finish()
                throw error
            }
            deviceSession = session
            return
        }
        let session = try MicSession(url: url)
        do { try session.start() } catch {
            _ = session.finish()
            throw error
        }
        self.session = session
    }

    public func pause() {
        session?.pause()
        deviceSession?.pause()
    }

    public func resume() throws {
        try session?.resume()
        try deviceSession?.resume()
    }

    nonisolated(nonsending) public func stop() async -> TrackResult {
        if let deviceSession {
            self.deviceSession = nil
            return deviceSession.finish()
        }
        guard let session else {
            return TrackResult(kind: .mic, url: URL(fileURLWithPath: "/dev/null"), seconds: 0, peakLevel: 0, error: "not recording")
        }
        self.session = nil
        return session.finish()
    }

    deinit {
        _ = session?.finish()
        _ = deviceSession?.finish()
    }
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
    private var startedAt: TimeInterval = 0  // systemUptime: monotonic; recording stops before the Mac sleeps
    private var pausedAt: TimeInterval?

    init(url: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError(description: "no microphone input available") }
        writer = try CAFWriter(url: url, format: format.streamDescription.pointee)
        fileFormat = format
    }

    func start() throws {
        startedAt = ProcessInfo.processInfo.systemUptime
        try lock.withLock { try installTapAndStart() }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// Stops the engine (the mic is let go) and writes nothing until `resume`.
    func pause() {
        lock.withLock {
            guard !finished, pausedAt == nil else { return }
            removeTap()
            pausedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// Carries on in the same file. The paused time is left out of the wall clock the gap padding measures against.
    func resume() throws {
        try lock.withLock {
            guard !finished, let pausedAt else { return }
            startedAt += ProcessInfo.processInfo.systemUptime - pausedAt
            self.pausedAt = nil
            try installTapAndStart()
        }
    }

    /// The engine has stopped itself; restart it on the (possibly different) new input. Not while paused.
    private func restartAfterConfigurationChange() {
        lock.withLock {
            guard !finished, pausedAt == nil else { return }
            removeTap()  // no tap may write while the gap is filled
            padToWallClock()
            do { try installTapAndStart() } catch where resumeError == nil {
                resumeError = "Microphone input changed at t=\(String(format: "%.1f", writer.seconds))s and could not be resumed: \(error)"
            } catch {}
        }
    }

    /// Writes silence for the time the engine was down, so every later mic line keeps its place
    /// against the meeting track. Runs on the notification thread, so allocating here is fine.
    /// ponytail: "down time" = wall clock minus frames written, so engine start latency is padded too (~tens of ms).
    private func padToWallClock() {
        let rate = fileFormat.sampleRate
        var missing = Int((ProcessInfo.processInfo.systemUptime - startedAt - writer.seconds) * rate)
        // Tap-sized chunks: one 1 s write overflowed the async writer's ring (OSStatus -66570).
        guard missing > Int(0.05 * rate), let silence = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: 4096) else { return }
        silence.frameLength = silence.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        while missing > 0 {
            silence.frameLength = AVAudioFrameCount(min(missing, Int(silence.frameCapacity)))
            writer.write(silence.audioBufferList, hostTime: 0)
            missing -= Int(silence.frameLength)
        }
    }

    private func removeTap() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        bridge?.flush()
        bridge = nil
    }

    private func installTapAndStart() throws {
        removeTap()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError(description: "no microphone input available") }
        if format == fileFormat {
            let writer = writer
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in writer.write(buffer.audioBufferList, hostTime: when.hostTime) }
        } else {
            let bridge = try FormatBridge(from: format, to: fileFormat, writer: writer)
            self.bridge = bridge
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in bridge.write(buffer, hostTime: when.hostTime) }
        }
        engine.prepare()
        try engine.start()
    }

    func finish() -> TrackResult {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        let error = lock.withLock {
            finished = true
            removeTap()
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

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        var supplied = false
        convert(hostTime: hostTime) { inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
    }

    /// Writes the samples the converter still holds. Call once, after the tap is removed.
    func flush() {
        convert(hostTime: 0) { inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
    }

    private func convert(hostTime: UInt64, _ input: (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) {
        withoutActuallyEscaping(input) { input in
            var status: AVAudioConverterOutputStatus
            repeat { // loops while the converter has more output than one buffer holds
                output.frameLength = 0
                status = converter.convert(to: output, error: nil) { _, inputStatus in input(inputStatus) }
                if output.frameLength > 0 { writer.write(output.audioBufferList, hostTime: hostTime) }
            } while status == .haveData
        }
    }
}
