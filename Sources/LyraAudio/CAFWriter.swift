import AudioToolbox
import Foundation
import LyraCore
import Synchronization

/// Writes Float32 PCM to a CAF in the capture's native rate and channel count, tracking length and peak.
/// `write` is real-time safe: no locks, no allocation, async file IO. A partially written CAF stays
/// readable after a crash, which is why capture uses CAF.
final class CAFWriter: Sendable {
    let url: URL
    private nonisolated(unsafe) let file: ExtAudioFileRef
    private let sampleRate: Double
    private let frames = Atomic<Int>(0)
    private let peakBits = Atomic<UInt32>(0)
    private let recentPeakBits = Atomic<UInt32>(0)
    private let writeStatus = Atomic<Int32>(0)
    private let firstHostTime = Atomic<UInt64>(0)  // host clock of the first buffer; 0 until one arrives

    init(url: URL, format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw AudioError(description: "unsupported capture format \(format)")
        }
        // CAF stores interleaved samples; ExtAudioFile interleaves non-interleaved client buffers for us.
        var fileFormat = format
        fileFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
        fileFormat.mBytesPerFrame = 4 * format.mChannelsPerFrame
        fileFormat.mBytesPerPacket = fileFormat.mBytesPerFrame
        var ref: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &fileFormat, nil,
                                            AudioFileFlags.eraseFile.rawValue, &ref), "create \(url.lastPathComponent)")
        guard let ref else { throw AudioError(description: "create \(url.lastPathComponent) returned no file") }
        var clientFormat = format
        do {
            try check(ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                              UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat), "set client format")
            try check(ExtAudioFileWriteAsync(ref, 0, nil), "prime async writer") // allocates now, not on the IO thread
        } catch {
            ExtAudioFileDispose(ref)
            throw error
        }
        self.url = url
        self.file = ref
        self.sampleRate = format.mSampleRate
    }

    /// The loudest sample of the latest buffer: how loud the source is now, for the recording bars.
    var recentPeak: Float { Float(bitPattern: recentPeakBits.load(ordering: .relaxed)) }

    /// Seconds written so far.
    var seconds: Double { Double(frames.load(ordering: .relaxed)) / sampleRate }

    /// Frame count comes from the first buffer's byte size (4 bytes per sample per channel).
    /// `hostTime` is when the buffer's first frame was captured; the first non-zero one is kept
    /// so the tracks can be lined up. Padding silence passes 0.
    func write(_ list: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frameCount = first.mDataByteSize / (4 * first.mNumberChannels)
        guard frameCount > 0 else { return }
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(buffer.mDataByteSize / 4) { peak = max(peak, abs(data[i])) }
        }
        // Non-negative floats order the same as their bit patterns.
        peakBits.max(peak.bitPattern, ordering: .relaxed)
        recentPeakBits.store(peak.bitPattern, ordering: .relaxed)
        let status = ExtAudioFileWriteAsync(file, frameCount, list)
        if status == noErr { frames.add(Int(frameCount), ordering: .relaxed) } else { writeStatus.store(status, ordering: .relaxed) }
        if hostTime != 0 { _ = firstHostTime.compareExchange(expected: 0, desired: hostTime, ordering: .relaxed) }
    }

    /// Closes the file. Call once, after the source has stopped delivering buffers.
    func finish(kind: TrackKind, extraError: String? = nil) -> TrackResult {
        let closeStatus = ExtAudioFileDispose(file)
        let writeStatus = writeStatus.load(ordering: .relaxed)
        let errors = [extraError,
                      writeStatus == noErr ? nil : "write failed (OSStatus \(writeStatus))",
                      closeStatus == noErr ? nil : "close failed (OSStatus \(closeStatus))"].compactMap { $0 }
        var result = TrackResult(kind: kind, url: url, seconds: seconds,
                                 peakLevel: Float(bitPattern: peakBits.load(ordering: .relaxed)),
                                 error: errors.isEmpty ? nil : errors.joined(separator: "; "))
        let first = firstHostTime.load(ordering: .relaxed)
        if first != 0 { result.firstFrameTime = Double(AudioConvertHostTimeToNanos(first)) / 1e9 }
        return result
    }
}
