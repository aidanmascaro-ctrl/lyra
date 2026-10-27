import AVFoundation
import LyraCore

/// One mic recording from a named device (the Mac's own mic, chosen by `MicChoice`) rather than the default input.
/// AVAudioEngine records only the Mac's default input, so this goes through AVCaptureSession, which can open any
/// mic without touching the headphones. Samples arrive as interleaved Float32 in the device's own rate.
final class DeviceMicSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "au.aidos.lyra.device-mic")
    private let writer: CAFWriter
    private let lock = NSLock()
    private var runtimeError: String?
    private var observer: NSObjectProtocol?

    init(url: URL, device: AVCaptureDevice) throws {
        guard let native = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee,
              native.mSampleRate > 0, native.mChannelsPerFrame > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.mSampleRate,
                                         channels: native.mChannelsPerFrame, interleaved: true) else {
            throw AudioError(description: "\(device.localizedName) has no usable audio format")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw AudioError(description: "\(device.localizedName) can't be recorded")
        }
        session.addInput(input)
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                                AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount]
        session.addOutput(output)
        writer = try CAFWriter(url: url, format: format.streamDescription.pointee)
        super.init()
    }

    func start() throws {
        output.setSampleBufferDelegate(self, queue: queue)
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                                          queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.lock.withLock { self?.runtimeError = self?.runtimeError ?? "Microphone stopped: \(error.map { "\($0)" } ?? "unknown error")" }
        }
        session.startRunning()
        guard session.isRunning else { throw AudioError(description: "the microphone could not be started") }
    }

    /// Stops capture (the mic is let go); nothing is written until `resume`.
    func pause() { session.stopRunning() }

    /// Carries on in the same file.
    func resume() throws {
        guard !session.isRunning else { return }
        session.startRunning()
        guard session.isRunning else { throw AudioError(description: "the microphone could not be restarted") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var block: CMBlockBuffer?
        var list = AudioBufferList()
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return }
        let hostTime = CMClockConvertHostTimeToSystemUnits(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        withUnsafePointer(to: &list) { writer.write($0, hostTime: hostTime) }
    }

    func finish() -> TrackResult {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        queue.sync {}  // the last buffer already handed to the delegate is written before the file closes
        return writer.finish(kind: .mic, extraError: lock.withLock { runtimeError })
    }
}
