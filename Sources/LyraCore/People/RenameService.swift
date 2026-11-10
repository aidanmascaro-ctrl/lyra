import Foundation

public enum RenameOutcome: Equatable, Sendable {
    case done
    /// Aidan edited the note's transcript section in Obsidian; the note was left alone (transcript.json and people.json
    /// are already updated). If he agrees to overwrite it, call `RenameService.rewriteNote` — that is the confirm action.
    case needsConfirmation
}

public enum RenameError: Error, LocalizedError {
    case noSuchSpeaker(String)
    /// transcript.json (and the note, per `outcome`) were updated, but the voice could not be learned.
    case notLearned(outcome: RenameOutcome, underlying: Error)
    /// The voice could not be learned and then the note could not be updated either; transcript.json was updated.
    case notLearnedAndNoteFailed(learnError: Error, noteError: Error)
    /// transcript.json was updated, but the note isn't where Lyra put it (e.g. Aidan moved it).
    case noteMissing(URL)

    public var errorDescription: String? {
        let voice = "The name was saved in the transcript, but Lyra couldn't remember this voice for future meetings. Renaming again won't retry it."
        switch self {
        case .noteMissing:
            return "The renamed transcript was saved, but the Obsidian note wasn't found at its original place, so it wasn't updated."
        case .noSuchSpeaker(let label): return "There is no one called “\(label)” in this meeting's transcript any more."
        case .notLearned(_, let e): return "\(voice) (\(e.localizedDescription))"
        case .notLearnedAndNoteFailed(let l, let n):
            return "\(voice) (\(l.localizedDescription)) The Obsidian note couldn't be updated either: \(n.localizedDescription)"
        }
    }
}

/// Renames one speaker in one meeting and learns their voice. Writes, in order: transcript.json → people.json → note.
public struct RenameService: Sendable {
    private let people: PeopleStore

    public init(people: PeopleStore) { self.people = people }

    @discardableResult
    public func rename(speakerLabel: String, to name: String, inMeetingFolder folder: URL, note: URL,
                       overwriteEditedNote: Bool = false) throws -> RenameOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleStoreError.emptyName }
        let transcriptURL = folder.appendingPathComponent("transcript.json")
        let before = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: transcriptURL))
        let picked = before.indices.filter { before[$0].speakerLabel == speakerLabel }
        guard !picked.isEmpty else { throw RenameError.noSuchSpeaker(speakerLabel) }
        // "Speaker N" is Lyra's own placeholder for unknown voices: relabel only, never learn a person called that.
        let isPlaceholder = trimmed.range(of: #"^speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let existing = isPlaceholder ? nil : people.person(named: trimmed)
        let display = isPlaceholder
            ? "Speaker " + trimmed.split(whereSeparator: \.isWhitespace).last!
            : existing?.name ?? trimmed

        // Same name: nothing to rename, but `.done` must still mean the note matches. A name heard in the conversation
        // is the exception: saying it again is Aidan's yes, so it becomes his name and the voice is learned.
        let confirmsHeard = picked.contains { before[$0].nameSource == .heard }
        if display == speakerLabel, !confirmsHeard {
            return try Self.writeTranscriptSection(lines: before, previous: before, folder: folder, note: note, overwrite: overwriteEditedNote)
        }

        var lines = before
        func label(_ id: UUID?) {
            for i in picked {
                lines[i].speakerLabel = display
                lines[i].personID = id
                lines[i].nameSource = .setByAidan
                lines[i].confidence = nil
            }
        }
        label(existing?.id)
        try MeetingProcessor.encoder.encode(lines).write(to: transcriptURL, options: .atomic)

        var learnError: Error?
        do {
            try forgetScreenLearned(picked.map { before[$0] }, in: folder)
            if !isPlaceholder, let person = try learn(from: picked.map { before[$0] }, all: before, as: display, in: folder),
               person.id != existing?.id {
                label(person.id)  // a new person: their id only exists now
                try MeetingProcessor.encoder.encode(lines).write(to: transcriptURL, options: .atomic)
            }
        } catch { learnError = error }

        let outcome: RenameOutcome
        do { outcome = try Self.writeTranscriptSection(lines: lines, previous: before, folder: folder, note: note, overwrite: overwriteEditedNote) }
        catch { throw learnError.map { RenameError.notLearnedAndNoteFailed(learnError: $0, noteError: error) } ?? error }
        if let learnError { throw RenameError.notLearned(outcome: outcome, underlying: learnError) }
        return outcome
    }

    /// As `rename(…note:)`, with the note found by its `lyra_id` (hint: `meeting.notePath`), wherever Aidan moved it.
    @discardableResult
    public func rename(speakerLabel: String, to name: String, inMeetingFolder folder: URL, index: NoteIndex,
                       overwriteEditedNote: Bool = false) throws -> RenameOutcome {
        try rename(speakerLabel: speakerLabel, to: name, inMeetingFolder: folder,
                   note: Self.noteURL(inMeetingFolder: folder, index: index), overwriteEditedNote: overwriteEditedNote)
    }

    public func rewriteNote(inMeetingFolder folder: URL, index: NoteIndex) throws {
        try rewriteNote(inMeetingFolder: folder, note: Self.noteURL(inMeetingFolder: folder, index: index))
    }

    /// Where the meeting's note is now. When it can't be found, the last known path, so the rename still updates
    /// transcript.json and then reports `noteMissing`.
    public static func noteURL(inMeetingFolder folder: URL, index: NoteIndex) throws -> URL {
        let meeting = try Meeting.load(from: folder)
        let hint = meeting.notePath.map { URL(fileURLWithPath: $0) }
        return index.find(meeting.id, hint: hint)
            ?? hint ?? index.notesRoot.appendingPathComponent(folder.lastPathComponent + ".md")
    }

    /// The confirm action for `.needsConfirmation`: re-renders the note's transcript section from the current
    /// transcript.json, overwriting Aidan's edits inside it (text outside the section is kept), and records the new hash.
    public func rewriteNote(inMeetingFolder folder: URL, note: URL) throws {
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        _ = try Self.writeTranscriptSection(lines: lines, previous: lines, folder: folder, note: note, overwrite: true)
    }

    /// Learns each of the speaker's clusters that speakers.json has. A join keeps only its first cluster's id, so for a
    /// known person every line carrying their personID counts. No speakers.json (Phase 1): learns nothing, returns nil.
    private func learn(from picked: [TranscriptLine], all: [TranscriptLine], as name: String, in folder: URL) throws -> Person? {
        let url = folder.appendingPathComponent("speakers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let clusters = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: url))
        let personIDs = Set(picked.compactMap(\.personID))
        let ids = Set((picked + all.filter { $0.personID.map(personIDs.contains) ?? false }).compactMap(\.speakerID))
        var person: Person?
        for c in clusters where ids.contains(c.id) {
            person = try people.learn(name: name, sample: c.centroid)  // isOwner false: learn never clears it
        }
        return person
    }

    /// Takes back the voice a tile taught: the lines were named from the call's screen and Aidan says that was wrong.
    private func forgetScreenLearned(_ lines: [TranscriptLine], in folder: URL) throws {
        let taught = lines.filter { $0.nameSource == .onScreen && $0.personID != nil }
        guard !taught.isEmpty else { return }
        let url = folder.appendingPathComponent("speakers.json")
        let clusters = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: url))
        for line in taught {  // forgetting a sample already gone does nothing
            guard let id = line.personID, let c = clusters.first(where: { $0.id == line.speakerID }) else { continue }
            try people.forget(sample: c.centroid, from: id)
        }
    }

    /// Rewrites the note's transcript section only if it is still as Lyra last wrote it (or Aidan said to overwrite).
    /// Shared with `TalkNamer`, which changes names in the same section.
    static func writeTranscriptSection(lines: [TranscriptLine], previous: [TranscriptLine], folder: URL, note: URL,
                           overwrite: Bool) throws -> RenameOutcome {
        var meeting = try Meeting.load(from: folder)
        let body = NoteRenderer.transcriptBody(lines: lines)
        // Read, compare and write under the note write lock, so Lyra's other saves and moves can't interleave.
        let written: RenameOutcome = try NoteIndex.withWriteLock {
            let text: String
            do { text = try String(contentsOf: note, encoding: .utf8) }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile { throw RenameError.noteMissing(note) }
            guard let current = NoteSections.transcriptBody(of: text) else { throw NoteSectionsError.missingTranscriptMarkers }
            // Old meetings have no hash: unedited only if the section still renders identically from the old transcript.
            let lyraWrote = meeting.transcriptSectionHash ?? NoteSections.hash(NoteRenderer.transcriptBody(lines: previous))
            // Already matching (e.g. Aidan made the same change himself): no write, just record the hash.
            guard current != body else { return .done }
            guard overwrite || NoteSections.hash(current) == lyraWrote else { return .needsConfirmation }
            do {
                try NoteIndex.writeAtomically(Data(NoteSections.replaceTranscript(in: text, with: body).utf8), to: note)
            } catch let e as CocoaError where e.code == .fileNoSuchFile { throw RenameError.noteMissing(note) }
            return .done
        }
        guard written == .done else { return written }
        if meeting.transcriptSectionHash != NoteSections.hash(body) || meeting.notePath != note.path {
            meeting.transcriptSectionHash = NoteSections.hash(body)
            meeting.notePath = note.path
            try meeting.save(in: folder)
        }
        return .done
    }
}
