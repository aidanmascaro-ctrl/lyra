import Foundation

/// One second of the call window: whose tile was lit, by name. Seconds on the recording's own timeline.
public struct OnScreenSample: Codable, Equatable, Sendable {
    public let t: Double
    public let name: String
    public init(t: Double, name: String) { self.t = t; self.name = name }
}

/// `onscreen.json` in the meeting folder: names and times only, never pictures.
public enum OnScreenLog {
    public static let fileName = "onscreen.json"

    /// No file (in-person, older meetings) or an unreadable one: no samples, so no names from the screen.
    public static func load(from folder: URL) -> [OnScreenSample] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([OnScreenSample].self, from: data)) ?? []
    }

    public static func save(_ samples: [OnScreenSample], in folder: URL) throws {
        try JSONEncoder().encode(samples).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }
}

/// Names call voices from the lit tiles seen while they spoke. Runs after `SpeakerNamer`, on call-track voices it
/// left unknown: Aidan and anyone in the room with him have no tile. A wrong name is worse than "Speaker N", so a
/// voice is named only when the tiles agree strongly and one name means one voice.
public enum OnScreenNamer {
    /// About this many seconds of lit tile while the voice spoke.
    static let minVotes = 6
    /// Share of the voice's lit-tile seconds that must show the one name.
    static let minShare = 0.75
    /// The ring moves a moment after the voice starts: a line's first half-second still shows the last speaker.
    static let lag = 0.5
    /// Two voices under one name are one person split by the diarizer only if they sound this alike.
    static let sameVoice: Float = 0.60

    public struct Learn: Equatable, Sendable {
        public let name: String
        public let clusters: [SpeakerCluster]
    }

    /// Lines with tile names filled in (`.onScreen`, confidence = vote share), remaining unknowns renumbered, and the
    /// voices to learn under each name. A name already in `people` joins that person; a new one has no id until learned.
    public static func name(lines: [TranscriptLine], clusters: [SpeakerCluster], samples: [OnScreenSample],
                            people: [Person]) -> (lines: [TranscriptLine], learn: [Learn]) {
        let byID = Dictionary(clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let winners = sureNames(lines: lines, samples: samples, byID: byID)
        let owner = people.filter(\.isOwner).map { key($0.name) }
        var named: [String: (display: String, person: Person?, clusters: [SpeakerCluster], share: Double)] = [:]
        for (k, group) in Dictionary(grouping: winners, by: { key($0.name) }) where !owner.contains(k) {
            let voices = group.map(\.cluster)
            let heard = heardAs(k, lines: lines, byID: byID)  // the same name already given to a voice by voice match
            guard allAlike(voices + heard) else { continue }
            let person = people.first { key($0.name) == k }
            named[k] = (person?.name ?? group[0].name, person, voices.sorted { $0.id < $1.id }, group.map(\.share).min() ?? 0)
        }
        let nameOf = Dictionary(named.values.flatMap { n in n.clusters.map { ($0.id, n) } }, uniquingKeysWith: { a, _ in a })
        var out = lines.map { line -> TranscriptLine in
            guard let id = line.speakerID, let n = nameOf[id], line.personID == nil else { return line }
            var l = line
            l.speakerLabel = n.display
            l.personID = n.person?.id
            l.nameSource = .onScreen
            l.confidence = n.share
            return l
        }
        renumberUnknowns(&out)
        let learn = named.values.map { Learn(name: $0.display, clusters: $0.clusters) }.sorted { $0.name < $1.name }
        return (out, learn)
    }

    /// Each still-unknown call voice whose lines' lit tiles clearly show one name.
    private static func sureNames(lines: [TranscriptLine], samples: [OnScreenSample],
                                  byID: [String: SpeakerCluster]) -> [(name: String, cluster: SpeakerCluster, share: Double)] {
        let sorted = samples.sorted { $0.t < $1.t }
        var votes: [String: [String: (count: Int, display: String)]] = [:]
        for line in lines where line.track == .meeting && line.personID == nil {
            guard let id = line.speakerID else { continue }
            for s in sorted where s.t >= line.start + lag && s.t <= line.end {
                let k = key(s.name)
                votes[id, default: [:]][k, default: (0, s.name)].count += 1
            }
        }
        return votes.compactMap { id, tally in
            let total = tally.values.reduce(0) { $0 + $1.count }
            guard let best = tally.values.max(by: { $0.count < $1.count }), let cluster = byID[id] else { return nil }
            let share = Double(best.count) / Double(total)
            guard best.count >= minVotes, share >= minShare else { return nil }
            return (best.display, cluster, share)
        }.sorted { $0.cluster.id < $1.cluster.id }
    }

    /// Clusters already named `k` by their voice in this meeting.
    private static func heardAs(_ k: String, lines: [TranscriptLine], byID: [String: SpeakerCluster]) -> [SpeakerCluster] {
        let ids = Set(lines.filter { $0.personID != nil && key($0.speakerLabel) == k }.compactMap(\.speakerID))
        return ids.sorted().compactMap { byID[$0] }
    }

    private static func allAlike(_ voices: [SpeakerCluster]) -> Bool {
        for (i, a) in voices.enumerated() {
            for b in voices[(i + 1)...] where (cosine(a.centroid, b.centroid) ?? -1) < sameVoice { return false }
        }
        return true
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard let ua = VoiceMatcher.unit(a), let ub = VoiceMatcher.unit(b), ua.count == ub.count else { return nil }
        return zip(ua, ub).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// "Speaker N" again by first appearance, so naming one voice from the screen leaves no gap in the numbers.
    private static func renumberUnknowns(_ lines: inout [TranscriptLine]) {
        var numbers: [String: Int] = [:]
        for i in lines.indices where lines[i].personID == nil && lines[i].nameSource == nil {
            let raw = lines[i].speakerID ?? lines[i].speakerLabel
            let n = numbers[raw] ?? numbers.count + 1
            numbers[raw] = n
            lines[i].speakerLabel = "Speaker \(n)"
        }
    }

    private static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
