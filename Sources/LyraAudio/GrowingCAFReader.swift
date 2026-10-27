import AVFoundation

/// Reads a CAF that a recorder is still writing, a little at a time. The file is reopened on every call
/// (a CAF being written has no final length in its header, so an open file would never see new frames)
/// and read from where the last call stopped. Only reads: the recording itself is never touched.
public final class GrowingCAFReader {
    public let url: URL
    private var position: AVAudioFramePosition = 0

    public init(url: URL) {
        self.url = url
    }

    /// The frames written since the last call, in the file's processing format; nil when there are none.
    public func readNew() throws -> AVAudioPCMBuffer? {
        let file = try AVAudioFile(forReading: url)
        let available = file.length - position
        guard available > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(available)) else {
            throw AudioError(description: "cannot make a \(available)-frame buffer for \(url.lastPathComponent)")
        }
        file.framePosition = position
        try file.read(into: buffer, frameCount: AVAudioFrameCount(available))
        position += AVAudioFramePosition(buffer.frameLength)
        return buffer.frameLength > 0 ? buffer : nil
    }
}
