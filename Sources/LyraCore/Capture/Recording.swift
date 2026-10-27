import Foundation

/// What one track recorder produced. `error` is nil when the whole track was captured cleanly.
public struct TrackResult: Codable, Sendable {
    public let kind: TrackKind
    public let url: URL
    public let seconds: Double
    public let peakLevel: Float
    public let error: String?
    /// Seconds after the earliest track's first frame that this track's first frame arrived; that track is 0.
    /// Nil when the track captured nothing, or in files saved before offsets were measured: treat as 0.
    public var startOffset: Double?
    /// Host clock (seconds) of the first captured frame. Only meaningful live, so never saved.
    public var firstFrameTime: Double?

    private enum CodingKeys: String, CodingKey { case kind, url, seconds, peakLevel, error, startOffset }

    public init(kind: TrackKind, url: URL, seconds: Double, peakLevel: Float, error: String?) {
        self.kind = kind; self.url = url; self.seconds = seconds; self.peakLevel = peakLevel; self.error = error
    }

    /// Sets each track's `startOffset` from its `firstFrameTime`, relative to the earliest one.
    public static func withStartOffsets(_ tracks: [TrackResult]) -> [TrackResult] {
        guard let earliest = tracks.compactMap(\.firstFrameTime).min() else { return tracks }
        return tracks.map { t in
            var t = t
            t.startOffset = t.firstFrameTime.map { $0 - earliest }
            return t
        }
    }
}

/// Records one audio source to a file. `start` throws if capture cannot begin; `stop` always returns a result.
/// `pause` lets go of the source and writes nothing until `resume`, which carries on in the same file.
public protocol TrackRecorder: AnyObject {
    func start(writingTo url: URL) throws
    func pause()
    func resume() throws
    nonisolated(nonsending) func stop() async -> TrackResult
}
