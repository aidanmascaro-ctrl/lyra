import AVFoundation
import FluidAudio
import Foundation

public enum AudioLoader {
    /// Reads any AVAudioFile-readable file (CAF, WAV, …) at any rate/channel count as 16 kHz mono Float32.
    /// Channels are averaged here: FluidAudio's own file path hands stereo to AVAudioConverter,
    /// which keeps only the left channel — the right one (e.g. a remote caller) would be lost.
    public static func load16kMono(url: URL) throws -> [Float] {
        try load16kMono(file: AVAudioFile(forReading: url))
    }

    /// Takes the open file so tests can hand in one whose reads misbehave.
    static func load16kMono(file: AVAudioFile) throws -> [Float] {
        let format = file.processingFormat  // deinterleaved Float32
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioConverterError.failedToCreateBuffer
        }
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            // Compressed files (AAC) can report a few more frames than they hold; a failed read in the
            // last chunk is the real end of the file. Earlier failures (a damaged CAF) still throw.
            do { try file.read(into: buffer, frameCount: chunk) } catch where !mono.isEmpty && file.length - file.framePosition <= AVAudioFramePosition(chunk) { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono.append(sum / Float(channels))
            }
        }
        // A read that stopped delivering frames well before the end is damage, not end-of-file:
        // say so rather than hand back a shorter meeting. Same bound as the catch above.
        if file.length - file.framePosition > AVAudioFramePosition(chunk) {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSFilePathErrorKey: file.url.path,
                NSLocalizedDescriptionKey: "audio stopped at \(file.framePosition) of \(file.length) frames"])
        }
        return try AudioConverter().resample(mono, from: format.sampleRate)
    }
}
