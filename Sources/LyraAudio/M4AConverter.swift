import AVFoundation
import LyraCore

public enum M4AConverter {
    /// CAF → AAC M4A. Throws unless the result opens with a non-zero duration, so the caller may delete the CAF.
    @Sendable public static func convert(_ caf: URL, to m4a: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: caf), presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError(description: "can't create M4A export for \(caf.lastPathComponent)")
        }
        try await session.export(to: m4a, as: .m4a)
        let duration = try await AVURLAsset(url: m4a).load(.duration)
        guard duration.seconds > 0 else { throw AudioError(description: "\(m4a.lastPathComponent) has zero duration") }
    }
}
