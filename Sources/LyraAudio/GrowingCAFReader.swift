import AVFoundation

/// Reads a CAF that a recorder is still writing, a little at a time. The file is reopened on every call
/// (a CAF being written has no final length in its header, so an open file would never see new frames)
/// and read from where the last call stopped. Only reads: the recording itself is never touched.
public final class GrowingCAFReader {
    /// The first read starts at most this far back: after a slow model download, the start of the meeting
    /// is left to the full transcript rather than read in one go (an hour of stereo is 1 GB).
    static let firstReadSeconds: Double = 20
    /// Each read returns at most this much, so a reader that is behind catches up in small steps.
    static let maxReadSeconds: Double = 5

    public let url: URL
    private var position: AVAudioFramePosition?  // nil until the first read

    public init(url: URL) {
        self.url = url
    }

    /// The next frames written since the last call, in the file's processing format; nil when there are none.
    public func readNew() throws -> AVAudioPCMBuffer? {
        let file = try AVAudioFile(forReading: url)
        guard let (start, count) = Self.span(after: position, length: file.length, sampleRate: file.processingFormat.sampleRate) else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw AudioError(description: "cannot make a \(count)-frame buffer for \(url.lastPathComponent)")
        }
        file.framePosition = start
        try file.read(into: buffer, frameCount: count)
        position = start + AVAudioFramePosition(buffer.frameLength)
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// Where the next read starts and how many frames it takes; nil when nothing new has been written.
    static func span(after position: AVAudioFramePosition?, length: AVAudioFramePosition,
                     sampleRate: Double) -> (start: AVAudioFramePosition, count: AVAudioFrameCount)? {
        let start = position ?? max(0, length - AVAudioFramePosition(firstReadSeconds * sampleRate))
        let available = length - start
        guard available > 0 else { return nil }
        return (start, AVAudioFrameCount(min(available, AVAudioFramePosition(maxReadSeconds * sampleRate))))
    }
}
