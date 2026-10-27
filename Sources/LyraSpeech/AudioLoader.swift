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
            guard buffer.frameLength > 0, buffer.floatChannelData != nil else { break }
            appendMono(of: buffer, to: &mono)
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

    /// One buffer of a growing recording as a 16 kHz mono Float32 buffer, channels averaged as above:
    /// the format FluidAudio's streaming ASR takes without converting again. Nil when it holds no frames.
    public static func mono16k(_ buffer: AVAudioPCMBuffer) throws -> sending AVAudioPCMBuffer? {
        var mono: [Float] = []
        appendMono(of: buffer, to: &mono)
        let samples = try AudioConverter().resample(mono, from: buffer.format.sampleRate)
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = out.floatChannelData else {
            throw AudioConverterError.failedToCreateBuffer
        }
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        out.frameLength = AVAudioFrameCount(samples.count)
        return out
    }

    /// Averages a deinterleaved Float32 buffer's channels onto the end of `mono`.
    private static func appendMono(of buffer: AVAudioPCMBuffer, to mono: inout [Float]) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        for i in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for c in 0..<channels { sum += data[c][i] }
            mono.append(sum / Float(channels))
        }
    }
}
