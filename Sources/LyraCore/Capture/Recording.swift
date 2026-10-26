import Foundation

/// What one track recorder produced. `error` is nil when the whole track was captured cleanly.
public struct TrackResult: Codable, Sendable {
    public let kind: TrackKind
    public let url: URL
    public let seconds: Double
    public let peakLevel: Float
    public let error: String?

    public init(kind: TrackKind, url: URL, seconds: Double, peakLevel: Float, error: String?) {
        self.kind = kind; self.url = url; self.seconds = seconds; self.peakLevel = peakLevel; self.error = error
    }
}

/// Records one audio source to a file. `start` throws if capture cannot begin; `stop` always returns a result.
public protocol TrackRecorder: AnyObject {
    func start(writingTo url: URL) throws
    nonisolated(nonsending) func stop() async -> TrackResult
}
