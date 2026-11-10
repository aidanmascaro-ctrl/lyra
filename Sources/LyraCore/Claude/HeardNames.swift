import Foundation

/// One name Claude heard for a "Speaker N" voice, with the transcript quotes that show it.
public struct HeardName: Codable, Equatable, Sendable {
    /// The placeholder label it names, e.g. "Speaker 3".
    public let speaker: String
    public let name: String
    /// Sure names go into the transcript; the rest stay suggestions on the speaker's pill.
    public let sure: Bool
    /// Short quotes, each checked to really be in the transcript and to mention the name.
    public let evidence: [String]
    /// Aidan said "Not them": never applied again, even when the step runs again.
    public var rejected: Bool?

    public init(speaker: String, name: String, sure: Bool, evidence: [String]) {
        self.speaker = speaker; self.name = name; self.sure = sure; self.evidence = evidence
    }
}

public enum HeardNamesError: Error, LocalizedError, Equatable {
    case noJSON

    public var errorDescription: String? {
        "Claude's answer didn't contain the speaker names Lyra asked for."
    }
}

/// Names from the conversation: Lyra's own checks on Claude's answer, applying sure names, and `heardnames.json`.
/// A wrong name is worse than "Speaker N", so anything that doesn't pass every check is dropped.
public enum HeardNames {
    public static let fileName = "heardnames.json"
    public static let maxNameChars = 40
    static let maxQuotes = 3
    static let maxQuoteChars = 200

    /// "Speaker N" voices nobody has named yet, in order of first appearance: the only ones Claude may name.
    public static func placeholders(in lines: [TranscriptLine]) -> [String] {
        var seen: Set<String> = []
        return lines.filter(isPlaceholder).map(\.speakerLabel).filter { seen.insert($0).inserted }
    }

    /// Claude's reply, checked. Throws only when there is no JSON object at all.
    public static func parse(_ reply: String, lines: [TranscriptLine]) throws -> [HeardName] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any]
        else { throw HeardNamesError.noJSON }
        let entries = object["speakers"] as? [[String: Any]] ?? []
        let open = Set(placeholders(in: lines))
        let spoken = lines.map { " " + normalised($0.text) + " " }

        let candidates = entries.compactMap { entry -> HeardName? in
            guard let speaker = entry["speaker"] as? String, open.contains(speaker),
                  let raw = entry["name"] as? String else { return nil }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= maxNameChars, !isPlaceholderName(name), !isTaken(name, in: lines) else { return nil }
            let quotes = (entry["evidence"] as? [String] ?? [])
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuoteChars)) }
                .filter { isReal($0, mentioning: name, in: spoken) }
            guard !quotes.isEmpty else { return nil }
            // Claude's "sure" stands only when a quote shows this voice: it introduces itself, or it answers next.
            let sure = (entry["sure"] as? Bool ?? false) && quotes.contains { showsVoice($0, of: name, is: speaker, in: lines) }
            return HeardName(speaker: speaker, name: name, sure: sure, evidence: Array(quotes.prefix(maxQuotes)))
        }
        // One name per speaker and one speaker per name; when the answer disagrees with itself, nobody is named.
        let speakerCounts = Dictionary(grouping: candidates, by: \.speaker).mapValues(\.count)
        let nameCounts = Dictionary(grouping: candidates, by: { key($0.name) }).mapValues(\.count)
        return candidates.filter { speakerCounts[$0.speaker] == 1 && nameCounts[key($0.name)] == 1 }
    }

    /// Lines with the sure, unrejected names in. Only placeholder lines change; they get `.heard` and no person:
    /// nobody's voice is learned until Aidan says yes. A name someone else already has in `lines` (Aidan may have
    /// given it while Claude was answering) is skipped.
    public static func apply(_ names: [HeardName], to lines: [TranscriptLine]) -> [TranscriptLine] {
        let usable = names.filter { $0.sure && $0.rejected != true && !isTaken($0.name, in: lines) }
        let byLabel = Dictionary(usable.map { ($0.speaker, $0.name) }, uniquingKeysWith: { first, _ in first })
        return lines.map { line in
            guard isPlaceholder(line), let name = byLabel[line.speakerLabel] else { return line }
            var l = line
            l.speakerLabel = name
            l.nameSource = .heard
            l.confidence = nil
            return l
        }
    }

    /// A fresh answer, with every speaker-and-name pair Aidan already said "Not them" to still rejected; then every
    /// earlier rejection (so "Not them" is never forgotten, whatever later answers say), and the earlier entries for
    /// speakers the fresh answer doesn't cover (names already applied keep their quotes).
    public static func merge(_ fresh: [HeardName], keepingRejectionsFrom old: [HeardName]) -> [HeardName] {
        let rejected = Set(old.filter { $0.rejected == true }.map { pair($0) })
        let marked = fresh.map { name in
            var n = name
            if rejected.contains(pair(name)) { n.rejected = true }
            return n
        }
        let covered = Set(fresh.map(\.speaker))
        let kept = Set(marked.map { pair($0) })
        return marked + old.filter { !kept.contains(pair($0)) && ($0.rejected == true || !covered.contains($0.speaker)) }
    }

    /// After a resumed recording is joined on, "Speaker N" labels may now mean other voices: only the names already
    /// in the transcript (looked up by name, not label) still mean what they did.
    public static func keepingApplied(_ names: [HeardName], in lines: [TranscriptLine]) -> [HeardName] {
        let heard = Set(lines.filter { $0.nameSource == .heard }.map { key($0.speakerLabel) })
        // "Not them"s stay too: the earlier part's labels don't change on a join, so they still mean the same voice.
        return names.filter { $0.rejected == true || ($0.sure && heard.contains(key($0.name))) }
    }

    /// The entry a speaker pill should explain: the applied name for a `.heard` label, or the open suggestion for a
    /// "Speaker N" label. Nil when there is nothing to show (no entry, or Aidan said "Not them").
    public static func entry(for label: String, source: NameSource?, in names: [HeardName]) -> HeardName? {
        let open = names.filter { $0.rejected != true }
        switch source {
        case .heard: return open.first { $0.sure && key($0.name) == key(label) }
        case nil: return isPlaceholderName(label) ? open.first { !$0.sure && $0.speaker == label } : nil
        default: return nil
        }
    }

    /// For showing: no file (older meetings, or the step hasn't run) or an unreadable one shows no names.
    public static func load(from folder: URL) -> [HeardName] {
        (try? loadForWriting(from: folder)) ?? []
    }

    /// For changing the file: no file is no names, but an unreadable one throws, so Aidan's "Not them"s in it are
    /// never written over.
    public static func loadForWriting(from folder: URL) throws -> [HeardName] {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([HeardName].self, from: Data(contentsOf: url))
    }

    public static func save(_ names: [HeardName], in folder: URL) throws {
        try MeetingProcessor.encoder.encode(names).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    // MARK: Checks

    static func isPlaceholder(_ line: TranscriptLine) -> Bool {
        line.personID == nil && line.nameSource == nil && isPlaceholderName(line.speakerLabel)
    }

    /// Already on a named speaker in `lines`, whole or by first name ("Sam" when "Sam Smith" is there, or the other way
    /// round): giving it again would split one person in two.
    private static func isTaken(_ name: String, in lines: [TranscriptLine]) -> Bool {
        let first = { (n: String) in normalised(n).split(separator: " ").first.map(String.init) ?? "" }
        let wanted = first(name)
        return lines.contains { !isPlaceholder($0) && (key($0.speakerLabel) == key(name) || first($0.speakerLabel) == wanted) }
    }

    private static func isPlaceholderName(_ name: String) -> Bool {
        name.range(of: #"^speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The quote is in some line of the transcript, as whole words (case, spacing and punctuation ignored), and names
    /// the person. `spoken` is each line normalised and padded with a space each side.
    private static func isReal(_ quote: String, mentioning name: String, in spoken: [String]) -> Bool {
        let q = normalised(quote)
        guard q.split(separator: " ").count >= 2 else { return false }
        let words = Set(q.split(separator: " ").map(String.init))
        guard normalised(name).split(separator: " ").contains(where: { words.contains(String($0)) }) else { return false }
        return spoken.contains { $0.contains(" \(q) ") }
    }

    /// Some line holding `quote` shows that `speaker` is the person: either it is that voice's own line and introduces
    /// the name ("I'm Sam"), or it is someone else's, the name is in its last sentence ("Thanks, Sam. Jo, you're up?"
    /// is a question for Jo), and the next voice to speak is `speaker` (it answered).
    /// A voice saying a name without introducing itself points away from it, so that never counts.
    private static func showsVoice(_ quote: String, of name: String, is speaker: String, in lines: [TranscriptLine]) -> Bool {
        let q = " " + normalised(quote) + " "
        return lines.indices.contains { i in
            guard (" " + normalised(lines[i].text) + " ").contains(q) else { return false }
            if lines[i].speakerLabel == speaker { return introduces(name, in: q) }
            let last = lastSentence(of: lines[i].text)
            guard mentions(name, in: last), !isAcknowledgement(last) else { return false }
            // A name said to whoever just finished ("Great work, Sam") can't be told from one for whoever's next.
            let quoter = lines[i].speakerLabel
            guard lines[..<i].last(where: { $0.speakerLabel != quoter })?.speakerLabel != speaker else { return false }
            return lines[(i + 1)...].first { $0.speakerLabel != quoter }?.speakerLabel == speaker
        }
    }

    /// "Thanks, Sam" and the like are for the person who just spoke, not the next one.
    private static func isAcknowledgement(_ sentence: String) -> Bool {
        let padded = " " + normalised(sentence) + " "
        return [" thanks ", " thank you ", " cheers ", " thankyou ", " ta "].contains { padded.contains($0) }
    }

    private static func lastSentence(of text: String) -> String {
        text.split(whereSeparator: { ".?!".contains($0) })
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? text
    }

    private static func mentions(_ name: String, in text: String) -> Bool {
        let words = Set(normalised(text).split(separator: " "))
        return normalised(name).split(separator: " ").contains { words.contains($0) }
    }

    /// "I'm Sam", "I am Sam", "my name's Sam", "my name is Sam", "Sam here" (normalised text). Not "this is Sam" (often
    /// someone else being introduced), and never "I'm Sam's…" (a possessive).
    private static func introduces(_ name: String, in normalisedQuote: String) -> Bool {
        guard let first = normalised(name).split(separator: " ").first else { return false }
        let padded = " \(normalised(normalisedQuote)) "
        let names = ["i m \(first)", "i am \(first)", "my name s \(first)", "my name is \(first)"]
            .contains { padded.contains(" \($0) ") && !padded.contains(" \($0) s ") }
        return names || (padded.contains(" \(first) here ") && !padded.contains(" \(first) s here "))
    }

    /// Lowercase letters and digits only, words split by single spaces.
    static func normalised(_ text: String) -> String {
        let kept = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func key(_ name: String) -> String { normalised(name) }

    private static func pair(_ n: HeardName) -> String { n.speaker + "\u{1F}" + key(n.name) }
}

/// Asks Claude who the "Speaker N" voices are, and checks the answer.
public enum HeardNamesService {
    /// No unnamed voices: nothing to ask, and no Claude call.
    public static func run(lines: [TranscriptLine], screenText: [String], people: [String],
                           claude: any ClaudeRunning) async throws -> [HeardName] {
        let open = HeardNames.placeholders(in: lines)
        guard !open.isEmpty else { return [] }
        let prompt = Prompts.heardNamesUser(lines: lines, toName: open, screenText: screenText, people: people)
        let reply = try await claude.complete(system: Prompts.heardNamesSystem, prompt: prompt)
        return try HeardNames.parse(reply, lines: lines)
    }
}
