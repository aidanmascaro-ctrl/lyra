import AVFoundation
import FluidAudio
import Foundation

public enum AudioLoader {
    /// Reads any AVAudioFile-readable file (CAF, WAV, …) at any rate/channel count as 16 kHz mono Float32.
    /// Channels are averaged here: FluidAudio's own file path hands stereo to AVAudioConverter,
    /// which keeps only the left channel — the right one (e.g. a remote caller) would be lost.
    public static func load16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat  // deinterleaved Float32
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioConverterError.failedToCreateBuffer
        }
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            // Compressed files (AAC) can report more frames than they hold; a failed read once audio
            // has arrived is the real end of the file.
            do { try file.read(into: buffer, frameCount: chunk) } catch where !mono.isEmpty { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono.append(sum / Float(channels))
            }
        }
        return try AudioConverter().resample(mono, from: format.sampleRate)
    }
}
