import Foundation

/// Teaching Lyra the owner's voice from a short mic recording.
public enum Enrolment {
    public static let ownerName = "Aidan"
    public static let minSpeechSeconds = 8.0

    /// Centroid of the cluster with the most speech (sum of its turns); nil if that is under `minSpeechSeconds`.
    public static func ownerSample(from diarization: Diarization) -> [Float]? {
        var speech: [String: Double] = [:]
        for t in diarization.turns { speech[t.speaker, default: 0] += t.end - t.start }
        // Ties break on the id so the pick never depends on dictionary order.
        guard let top = speech.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              top.value >= minSpeechSeconds else { return nil }
        return diarization.centroids[top.key]
    }

    /// Diarizes 16 kHz mono `samples` and adds the owner sample to `people`. False: too little speech, nothing saved.
    /// Throws the diarizer's or the store's error. Re-running adds another sample.
    public static func enrol(samples: [Float], diarizer: SpeakerDiarizing, people: PeopleStore) async throws -> Bool {
        guard let sample = ownerSample(from: try await diarizer.diarize(samples: samples)) else { return false }
        try people.learn(name: ownerName, sample: sample, isOwner: true)
        return true
    }
}
