import Foundation

/// One speaker row in the meeting window.
public struct SpeakerSummary: Equatable, Sendable {
    public let label: String
    /// `.setByAidan` if any of the label's lines was named by hand, else `.knownVoice` if any was matched, else
    /// `.onScreen` if any was read off the call's tiles, else nil.
    public let source: NameSource?
    /// Sum of the label's line durations.
    public let seconds: Double

    public init(label: String, source: NameSource?, seconds: Double) {
        self.label = label; self.source = source; self.seconds = seconds
    }
}

public enum MeetingOverview {
    /// Speakers in order of first appearance.
    public static func speakers(in lines: [TranscriptLine]) -> [SpeakerSummary] {
        var order: [String] = []
        var seconds: [String: Double] = [:]
        var sources: [String: Set<NameSource>] = [:]
        for l in lines {
            if seconds[l.speakerLabel] == nil { order.append(l.speakerLabel) }
            seconds[l.speakerLabel, default: 0] += l.end - l.start
            if let s = l.nameSource { sources[l.speakerLabel, default: []].insert(s) }
        }
        return order.map { label in
            let s = sources[label] ?? []
            return SpeakerSummary(label: label, source: [.setByAidan, .knownVoice, .onScreen].first(where: s.contains), seconds: seconds[label] ?? 0)
        }
    }

    /// Names the people pill shows before the rest become "+N".
    public static let peopleShown = 3

    /// "Me, Marco, Tomas +1": the first few names, short, then how many more.
    public static func peoplePill(_ names: [String]) -> String {
        let shown = names.prefix(peopleShown).map(shortName).joined(separator: ", ")
        let more = names.count - peopleShown
        return more > 0 ? "\(shown) +\(more)" : shown
    }

    /// Aidan's own label without its microphone note ("Me (room mic)" → "Me"); everyone else as labelled.
    public static func shortName(_ name: String) -> String {
        name.hasPrefix("Me (") && name.hasSuffix(")") ? "Me" : name
    }

    /// The processed meeting (has transcript.json and a readable meeting.json) that started most recently.
    public static func lastFolder(in root: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path) }
            .compactMap { f in (try? Meeting.load(from: f)).map { (f, $0.startedAt) } }
            .max { $0.1 < $1.1 }?.0
    }
}
