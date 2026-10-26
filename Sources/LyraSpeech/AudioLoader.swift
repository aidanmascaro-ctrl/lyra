import FluidAudio
import Foundation

public enum AudioLoader {
    /// Reads any AVAudioFile-readable file (CAF, WAV, …) at any rate/channel count as 16 kHz mono Float32.
    public static func load16kMono(url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}
