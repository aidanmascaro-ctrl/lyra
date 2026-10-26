import Foundation

public enum RenameOutcome: Equatable, Sendable {
    case done
    /// Aidan edited the note's transcript section in Obsidian; the note was left alone. Ask, then call again with
    /// `speakerLabel` = the new name, `to:` the same name and `overwriteEditedNote: true` (that call only rewrites the note).
    case needsConfirmation
}

public enum RenameError: Error {
    case noSuchSpeaker(String)
    /// transcript.json (and the note, per `outcome`) were updated, but the voice could not be learned.
    case notLearned(outcome: RenameOutcome, underlying: Error)
}

/// Renames one speaker in one meeting and learns their voice. Writes, in order: transcript.json → people.json → note.
public struct RenameService {
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
        let existing = people.person(named: trimmed)
        let display = existing?.name ?? trimmed

        if display == speakerLabel {  // same name: nothing to change, except the note when Aidan confirmed overwriting it
            return overwriteEditedNote ? try writeNote(lines: before, previous: before, folder: folder, note: note, overwrite: true) : .done
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
            if let person = try learn(from: picked.map { before[$0] }, all: before, as: display, in: folder),
               person.id != existing?.id {
                label(person.id)  // a new person: their id only exists now
                try MeetingProcessor.encoder.encode(lines).write(to: transcriptURL, options: .atomic)
            }
        } catch { learnError = error }

        let outcome = try writeNote(lines: lines, previous: before, folder: folder, note: note, overwrite: overwriteEditedNote)
        if let learnError { throw RenameError.notLearned(outcome: outcome, underlying: learnError) }
        return outcome
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

    /// Rewrites the note's transcript section only if it is still as Lyra last wrote it (or Aidan said to overwrite).
    private func writeNote(lines: [TranscriptLine], previous: [TranscriptLine], folder: URL, note: URL,
                           overwrite: Bool) throws -> RenameOutcome {
        var meeting = try Meeting.load(from: folder)
        let text = try String(contentsOf: note, encoding: .utf8)
        guard let current = NoteSections.transcriptBody(of: text) else { throw NoteSectionsError.missingTranscriptMarkers }
        // Old meetings have no hash: unedited only if the section still renders identically from the old transcript.
        let lyraWrote = meeting.transcriptSectionHash ?? NoteSections.hash(NoteRenderer.transcriptBody(lines: previous))
        guard overwrite || NoteSections.hash(current) == lyraWrote else { return .needsConfirmation }
        let body = NoteRenderer.transcriptBody(lines: lines)
        try NoteSections.replaceTranscript(in: text, with: body).write(to: note, atomically: true, encoding: .utf8)
        meeting.transcriptSectionHash = NoteSections.hash(body)
        try meeting.save(in: folder)
        return .done
    }
}
