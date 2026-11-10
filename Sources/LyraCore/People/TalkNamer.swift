import Foundation

/// Names a meeting's "Speaker N" voices from the conversation, in its recording folder. Writes, in order:
/// heardnames.json → transcript.json → the note's transcript section (only while it is still as Lyra wrote it) →
/// meeting.json (`namesDone`). Never learns a voice: that waits for Aidan's yes, through `RenameService`.
public struct TalkNamer: Sendable {
    private let claude: any ClaudeRunning
    private let people: @Sendable () -> [String]

    /// `people` is the names Lyra knows, read once per run: candidates for spelling only, never evidence.
    public init(claude: any ClaudeRunning, people: @escaping @Sendable () -> [String] = { [] }) {
        self.claude = claude
        self.people = people
    }

    public struct Outcome: Equatable, Sendable {
        /// Every checked name in heardnames.json, sure or not.
        public let names: [HeardName]
        /// `.needsConfirmation`: the note's transcript was edited by hand, so only transcript.json has the names.
        public let note: RenameOutcome
    }

    /// Asks Claude, keeps Aidan's earlier "Not them"s, and puts this answer's sure names in. A Claude failure throws
    /// before anything is written.
    @discardableResult
    public func run(folder: URL, note: URL) async throws -> Outcome {
        let meeting = try Meeting.load(from: folder)
        let asked = try Self.transcript(in: folder)
        let fresh = try await HeardNamesService.run(lines: asked, screenText: meeting.screenText ?? [],
                                                    people: people(), claude: claude)
        let names = HeardNames.merge(fresh, keepingRejectionsFrom: try HeardNames.loadForWriting(from: folder))
        try HeardNames.save(names, in: folder)
        // Read again: Aidan may have renamed someone while Claude was answering. `apply` only fills voices still
        // "Speaker N" with names nobody has, and only from this answer, never an older one whose label may be stale.
        let current = try Self.transcript(in: folder)
        let answered = Set(fresh.map(\.speaker))
        let outcome = try Self.replaceLines(current, with: HeardNames.apply(names.filter { answered.contains($0.speaker) }, to: current),
                                            folder: folder, note: note)
        try AfterMeeting.updateMeeting(in: folder) { $0.namesDone = true; $0.namesError = nil }
        return Outcome(names: names, note: outcome)
    }

    /// Aidan's "Not them" on `heard`: remembered in heardnames.json so no later run brings it back, and an applied
    /// name goes back to its "Speaker N". `.needsConfirmation` when the note's transcript was edited by hand
    /// (transcript.json is updated either way; `RenameService.rewriteNote` is the confirm).
    @discardableResult
    public static func reject(_ heard: HeardName, folder: URL, note: URL) throws -> RenameOutcome {
        let before = try transcript(in: folder)
        let applied = before.contains { $0.nameSource == .heard && $0.speakerLabel == heard.name }
        // Its old "Speaker N" may now belong to a resumed part's new voice: never let two voices share a label.
        let label = applied ? freeLabel(preferring: heard.speaker, in: before) : heard.speaker
        var names = try HeardNames.loadForWriting(from: folder).map { n -> HeardName in
            var n = n
            if n.speaker == heard.speaker, n.name == heard.name { n.rejected = true }
            return n
        }
        if label != heard.speaker {  // the "Not them" follows the voice to its new label
            var moved = HeardName(speaker: label, name: heard.name, sure: heard.sure, evidence: heard.evidence)
            moved.rejected = true
            names.append(moved)
        }
        try HeardNames.save(names, in: folder)
        let after = before.map { line -> TranscriptLine in
            guard line.nameSource == .heard, line.speakerLabel == heard.name else { return line }
            var l = line
            l.speakerLabel = label
            l.nameSource = nil
            return l
        }
        return try replaceLines(before, with: after, folder: folder, note: note)
    }

    /// `preferred` when no line uses it, else the next "Speaker N" after the highest in use.
    private static func freeLabel(preferring preferred: String, in lines: [TranscriptLine]) -> String {
        guard lines.contains(where: { $0.speakerLabel == preferred }) else { return preferred }
        let numbers = lines.compactMap { line -> Int? in
            guard line.speakerLabel.hasPrefix("Speaker ") else { return nil }
            return Int(line.speakerLabel.dropFirst("Speaker ".count))
        }
        return "Speaker \((numbers.max() ?? 0) + 1)"
    }

    /// A resumed recording was joined on: keep only the names already in the transcript, and let naming run again for
    /// the new part's voices.
    public static func afterJoin(folder: URL, lines: [TranscriptLine]) throws {
        let names = try HeardNames.loadForWriting(from: folder)
        guard !names.isEmpty else { return }
        try HeardNames.save(HeardNames.keepingApplied(names, in: lines), in: folder)
    }

    @discardableResult
    private static func replaceLines(_ before: [TranscriptLine], with after: [TranscriptLine], folder: URL,
                                     note: URL) throws -> RenameOutcome {
        guard after != before else { return .done }
        try MeetingProcessor.encoder.encode(after).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        return try RenameService.writeTranscriptSection(lines: after, previous: before, folder: folder, note: note, overwrite: false)
    }

    private static func transcript(in folder: URL) throws -> [TranscriptLine] {
        try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
    }
}
