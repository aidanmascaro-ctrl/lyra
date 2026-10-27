import Foundation

/// What Claude works out about a finished meeting, ready for the note's frontmatter.
public struct MeetingInsights: Codable, Equatable, Sendable {
    public var title: String
    public var tags: [String]
    public var clients: [String]
    public var series: String?
    public var summary: String

    public init(title: String, tags: [String], clients: [String], series: String?, summary: String) {
        self.title = title; self.tags = tags; self.clients = clients; self.series = series; self.summary = summary
    }
}

public struct InsightsInput: Sendable {
    public var windowTitle: String
    public var screenText: [String]
    public var transcript: [TranscriptLine]
    public var myNotes: String
    /// Series name → its recent meeting titles.
    public var existingSeries: [String: [String]]
    public var knownTags: [String]
    public var clients: [String]
    public var people: [String]

    public init(windowTitle: String, screenText: [String] = [], transcript: [TranscriptLine] = [], myNotes: String = "",
                existingSeries: [String: [String]] = [:], knownTags: [String] = [], clients: [String] = [],
                people: [String] = []) {
        self.windowTitle = windowTitle; self.screenText = screenText; self.transcript = transcript
        self.myNotes = myNotes; self.existingSeries = existingSeries; self.knownTags = knownTags
        self.clients = clients; self.people = people
    }
}

public enum InsightsError: Error, LocalizedError, Equatable {
    case noJSON
    case missingKeys([String])

    public var errorDescription: String? {
        switch self {
        case .noJSON: "Claude's answer didn't contain the meeting details Lyra asked for."
        case .missingKeys(let keys): "Claude's answer left out: \(keys.joined(separator: ", "))."
        }
    }
}

public enum InsightsService {
    private static let titleLengths = 3...80
    private static let maxTags = 6
    private static let maxSummaryChars = 140

    public static func run(_ input: InsightsInput, claude: ClaudeRunning) async throws -> MeetingInsights {
        let reply = try await claude.complete(system: Prompts.insightsSystem, prompt: Prompts.insightsUser(input: input))
        return try parse(reply, input: input)
    }

    public static func parse(_ json: String, input: InsightsInput) throws -> MeetingInsights {
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(json[start...end].utf8)) as? [String: Any]
        else { throw InsightsError.noJSON }
        let missing = ["title", "tags", "summary"].filter { object[$0] == nil || object[$0] is NSNull }
        guard missing.isEmpty else { throw InsightsError.missingKeys(missing) }

        return MeetingInsights(
            title: title(object["title"] as? String, fallback: input.windowTitle),
            tags: tags(object["tags"] as? [String] ?? [], known: input.knownTags),
            clients: clients(object["clients"] as? [String] ?? [], allowed: input.clients),
            series: series(object["series"] as? String, existing: Array(input.existingSeries.keys)),
            summary: summary(object["summary"] as? String ?? "")
        )
    }

    /// Every tag used in `notes`, without "meeting", deduplicated and sorted.
    public static func knownTags(in notes: [LoadedNote]) -> [String] {
        Array(Set(notes.flatMap { $0.document.front.tags }.filter { $0 != "meeting" })).sorted()
    }

    /// Folder names directly under `<vault>/Clients/`, sorted.
    public static func clients(inVault vault: URL) -> [String] {
        let folder = vault.appendingPathComponent("Clients", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: Cleaning Claude's answer

    private static func title(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return titleLengths.contains(trimmed.count) ? trimmed : fallback
    }

    static func normaliseTag(_ raw: String) -> String {
        let dashed = raw.lowercased().map { $0 == " " || $0 == "_" ? "-" : $0 }
        let kept = dashed.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
        return String(kept).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    private static func tags(_ raw: [String], known: [String]) -> [String] {
        var byNormalised: [String: String] = [:]
        for tag in known where byNormalised[normaliseTag(tag)] == nil { byNormalised[normaliseTag(tag)] = tag }
        var seen: Set<String> = []
        var result: [String] = []
        for tag in raw {
            let normalised = normaliseTag(tag)
            guard !normalised.isEmpty, normalised != "meeting", seen.insert(normalised).inserted else { continue }
            result.append(byNormalised[normalised] ?? normalised)
            if result.count == maxTags { break }
        }
        return result
    }

    private static func clients(_ raw: [String], allowed: [String]) -> [String] {
        var result: [String] = []
        for name in raw {
            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let match = allowed.first(where: { $0.lowercased() == wanted }), !result.contains(match) else { continue }
            result.append(match)
        }
        return result
    }

    private static func series(_ raw: String?, existing: [String]) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        return existing.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased() } ?? trimmed
    }

    private static func summary(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxSummaryChars else { return trimmed }
        let cut = trimmed.prefix(maxSummaryChars)
        let endsOnWord = trimmed[trimmed.index(trimmed.startIndex, offsetBy: maxSummaryChars)].isWhitespace
        guard !endsOnWord, let space = cut.lastIndex(where: \.isWhitespace) else {
            return String(cut).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(cut[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
