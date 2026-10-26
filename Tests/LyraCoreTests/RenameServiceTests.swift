@testable import LyraCore
import XCTest

final class RenameServiceTests: XCTestCase {
    private var dir: URL!
    private var store: PeopleStore!
    private var peopleURL: URL { dir.appendingPathComponent("people.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = PeopleStore(fileURL: peopleURL)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func line(_ label: String, _ id: String?, _ t: Double, _ text: String) -> TranscriptLine {
        TranscriptLine(speakerLabel: label, speakerID: id, track: .meeting, start: t, end: t + 1, text: text)
    }

    private var standardLines: [TranscriptLine] {
        [line("Speaker 1", "meeting:A", 0, "hi"), line("Speaker 2", "meeting:B", 2, "one"),
         line("Speaker 1", "meeting:A", 4, "again"), line("Speaker 2", "meeting:B", 6, "two")]
    }

    private let standardSpeakers = [
        SpeakerCluster(id: "meeting:A", track: .meeting, centroid: [1, 0, 0], speechSeconds: 2),
        SpeakerCluster(id: "meeting:B", track: .meeting, centroid: [0, 1, 0], speechSeconds: 2),
        SpeakerCluster(id: "meeting:C", track: .meeting, centroid: [0, 0, 1], speechSeconds: 2),
    ]

    /// Writes a meeting folder the way MeetingProcessor leaves it; returns (folder, note).
    private func makeMeeting(_ name: String = "m1", lines: [TranscriptLine]? = nil, storeHash: Bool = true) throws -> (URL, URL) {
        let lines = lines ?? standardLines
        let folder = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meeting = Meeting(title: "Call", appName: "zoom.us", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let note = dir.appendingPathComponent("\(name).md")
        try NoteRenderer.render(meeting: meeting, lines: lines, recordingsFolder: folder).write(to: note, atomically: true, encoding: .utf8)
        if storeHash { meeting.transcriptSectionHash = NoteSections.hash(NoteRenderer.transcriptBody(lines: lines)) }
        try meeting.save(in: folder)
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent("transcript.json"))
        try JSONEncoder().encode(standardSpeakers).write(to: folder.appendingPathComponent("speakers.json"))
        return (folder, note)
    }

    private func lines(_ folder: URL) throws -> [TranscriptLine] {
        try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
    }

    private func editNote(_ note: URL, _ from: String, _ to: String) throws {
        try String(contentsOf: note, encoding: .utf8).replacingOccurrences(of: from, with: to)
            .write(to: note, atomically: true, encoding: .utf8)
    }

    func testRenameUpdatesAllLinesOfThatSpeaker() throws {
        let (folder, note) = try makeMeeting()
        let outcome = try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Marco", inMeetingFolder: folder, note: note)
        XCTAssertEqual(outcome, .done)
        let out = try lines(folder)
        XCTAssertEqual(out.map(\.speakerLabel), ["Speaker 1", "Marco", "Speaker 1", "Marco"])
        let marco = try XCTUnwrap(store.person(named: "Marco"))
        for l in out where l.speakerLabel == "Marco" {
            XCTAssertEqual(l.nameSource, .setByAidan); XCTAssertEqual(l.personID, marco.id); XCTAssertNil(l.confidence)
        }
        XCTAssertNil(out[0].nameSource)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(NoteSections.transcriptBody(of: text), NoteRenderer.transcriptBody(lines: out))
        XCTAssertFalse(text.contains("Speaker 2"))
        XCTAssertEqual(try Meeting.load(from: folder).transcriptSectionHash, NoteSections.hash(NoteRenderer.transcriptBody(lines: out)))
    }

    func testRenameLearnsCentroids() throws {
        let (folder, note) = try makeMeeting()
        try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Marco", inMeetingFolder: folder, note: note)
        let marco = try XCTUnwrap(store.person(named: "Marco"))
        XCTAssertEqual(marco.samples, [[0, 1, 0]])  // only B: C is on no line, A is someone else
        XCTAssertFalse(marco.isOwner)
        XCTAssertEqual(PeopleStore(fileURL: peopleURL).person(named: "Marco")?.samples, [[0, 1, 0]])

        // A known person relabelled: their clusters (all lines with their personID) go to the new name;
        // an id missing from speakers.json is never learned.
        var known = [line("Marco", "meeting:B", 0, "x"), line("Marco", "meeting:Z", 2, "y")]
        for i in known.indices { known[i].personID = marco.id; known[i].nameSource = .knownVoice; known[i].confidence = 0.9 }
        let (f2, n2) = try makeMeeting("m2", lines: known)
        try RenameService(people: store).rename(speakerLabel: "Marco", to: "Paul", inMeetingFolder: f2, note: n2)
        XCTAssertEqual(store.person(named: "Paul")?.samples, [[0, 1, 0]])
        XCTAssertEqual(store.person(named: "Marco")?.samples, [[0, 1, 0]])
    }

    func testRenameExistingPersonDifferentCase() throws {
        let existing = try store.learn(name: "Marco", sample: [0, 0.9, 0.1], isOwner: true)
        let (folder, note) = try makeMeeting()
        try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "  marco ", inMeetingFolder: folder, note: note)
        XCTAssertEqual(store.all().count, 1)
        let marco = try XCTUnwrap(store.person(named: "Marco"))
        XCTAssertEqual(marco.id, existing.id)
        XCTAssertEqual(marco.name, "Marco")
        XCTAssertEqual(marco.samples.count, 2)
        XCTAssertTrue(marco.isOwner)  // rename never changes isOwner
        XCTAssertEqual(try lines(folder).filter { $0.personID == existing.id }.map(\.speakerLabel), ["Marco", "Marco"])
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("**Marco** [00:00:02] one"))
    }

    func testEditedSectionNeedsConfirmation() throws {
        let (folder, note) = try makeMeeting()
        try editNote(note, "] two", "] two (edited by Aidan)")
        let before = try Data(contentsOf: note)
        let hashBefore = try Meeting.load(from: folder).transcriptSectionHash
        let outcome = try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Marco", inMeetingFolder: folder, note: note)
        XCTAssertEqual(outcome, .needsConfirmation)
        XCTAssertEqual(try Data(contentsOf: note), before)
        XCTAssertEqual(try lines(folder).map(\.speakerLabel), ["Speaker 1", "Marco", "Speaker 1", "Marco"])
        XCTAssertNotNil(store.person(named: "Marco"))
        XCTAssertEqual(try Meeting.load(from: folder).transcriptSectionHash, hashBefore)
    }

    func testOverwriteWhenConfirmed() throws {
        try store.learn(name: "Marco", sample: [0, 1, 0])
        let (folder, note) = try makeMeeting()
        try editNote(note, "] two", "] two (edited)")
        try editNote(note, "<!-- lyra:notes:start -->\n", "<!-- lyra:notes:start -->\nmy notes\n")
        let service = RenameService(people: store)
        XCTAssertEqual(try service.rename(speakerLabel: "Speaker 2", to: "marco", inMeetingFolder: folder, note: note), .needsConfirmation)
        // Aidan confirms: rewriteNote is the confirm action; it doesn't learn again.
        try service.rewriteNote(inMeetingFolder: folder, note: note)
        let text = try String(contentsOf: note, encoding: .utf8)
        let out = try lines(folder)
        XCTAssertEqual(out.map(\.speakerLabel), ["Speaker 1", "Marco", "Speaker 1", "Marco"])
        XCTAssertEqual(NoteSections.transcriptBody(of: text), NoteRenderer.transcriptBody(lines: out))
        XCTAssertTrue(text.contains("<!-- lyra:notes:start -->\nmy notes\n"))
        XCTAssertEqual(store.person(named: "Marco")?.samples.count, 2)
        XCTAssertEqual(try Meeting.load(from: folder).transcriptSectionHash, NoteSections.hash(NoteRenderer.transcriptBody(lines: out)))
        // Now the note matches, a later rename goes straight through.
        XCTAssertEqual(try service.rename(speakerLabel: "Speaker 1", to: "Ann", inMeetingFolder: folder, note: note), .done)

        // Overwrite straight away also works.
        let (f2, n2) = try makeMeeting("m2")
        try editNote(n2, "] one", "] one!")
        XCTAssertEqual(try service.rename(speakerLabel: "Speaker 1", to: "Ann", inMeetingFolder: f2, note: n2, overwriteEditedNote: true), .done)
        XCTAssertTrue(try String(contentsOf: n2, encoding: .utf8).contains("**Ann** [00:00:00] hi"))
    }

    /// `.done` always means the note matches: a same-name rename over an edited section still asks.
    func testSameNameWithEditedSectionNeedsConfirmation() throws {
        let (folder, note) = try makeMeeting()
        try editNote(note, "] two", "] two!")
        let before = try Data(contentsOf: note)
        XCTAssertEqual(try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Speaker 2", inMeetingFolder: folder, note: note),
                       .needsConfirmation)
        XCTAssertEqual(try Data(contentsOf: note), before)
    }

    func testSameNameIsNoOp() throws {
        let (folder, note) = try makeMeeting()
        let before = try Data(contentsOf: folder.appendingPathComponent("transcript.json"))
        let noteBefore = try Data(contentsOf: note)
        XCTAssertEqual(try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: " Speaker 2", inMeetingFolder: folder, note: note), .done)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("transcript.json")), before)
        XCTAssertEqual(try Data(contentsOf: note), noteBefore)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testOtherMeetingsUntouched() throws {
        let (folder, note) = try makeMeeting("m1")
        let (other, otherNote) = try makeMeeting("m2")
        let otherLines = try Data(contentsOf: other.appendingPathComponent("transcript.json"))
        let otherText = try Data(contentsOf: otherNote)
        try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Marco", inMeetingFolder: folder, note: note)
        XCTAssertEqual(try Data(contentsOf: other.appendingPathComponent("transcript.json")), otherLines)
        XCTAssertEqual(try Data(contentsOf: otherNote), otherText)
    }

    func testPhase1FolderRenamesWithoutLearning() throws {
        let phase1 = [line("Speaker 1", nil, 0, "hi"), line("Speaker 2", nil, 2, "yo"), line("Speaker 2", nil, 4, "ok")]
        let (folder, note) = try makeMeeting(lines: phase1, storeHash: false)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("speakers.json"))
        XCTAssertEqual(try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Marco", inMeetingFolder: folder, note: note), .done)
        XCTAssertEqual(try lines(folder).map(\.speakerLabel), ["Speaker 1", "Marco", "Marco"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: peopleURL.path))
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("**Marco** [00:00:02] yo"))

        // Old meeting (no hash) whose section Aidan edited: ask first.
        let (f2, n2) = try makeMeeting("m2", lines: phase1, storeHash: false)
        try FileManager.default.removeItem(at: f2.appendingPathComponent("speakers.json"))
        try editNote(n2, "] yo", "] yo!")
        XCTAssertEqual(try RenameService(people: store).rename(speakerLabel: "Speaker 1", to: "Ann", inMeetingFolder: f2, note: n2), .needsConfirmation)
    }

    func testUnknownLabelThrows() throws {
        let (folder, note) = try makeMeeting()
        XCTAssertThrowsError(try RenameService(people: store).rename(speakerLabel: "Speaker 9", to: "X", inMeetingFolder: folder, note: note))
        XCTAssertThrowsError(try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "  ", inMeetingFolder: folder, note: note))
    }

    /// Learning fails (voice of another dimension): the names still land, and the error says what was done.
    func testLearnFailureStillRenames() throws {
        try store.learn(name: "Marco", sample: [1, 0])
        let (folder, note) = try makeMeeting()
        XCTAssertThrowsError(try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Marco", inMeetingFolder: folder, note: note)) {
            guard case RenameError.notLearned(.done, PeopleStoreError.dimensionMismatch) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try lines(folder).map(\.speakerLabel), ["Speaker 1", "Marco", "Speaker 1", "Marco"])
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("**Marco** [00:00:02] one"))
        XCTAssertEqual(store.person(named: "Marco")?.samples, [[1, 0]])
    }

    /// A known person's other line with a different label (Aidan relabelled one line set earlier) still counts.
    func testLearnsEveryClusterOfTheKnownPerson() throws {
        let marco = try store.learn(name: "Marco", sample: [0, 1, 0])
        var a = line("Marco", "meeting:B", 0, "x"), b = line("J.", "meeting:C", 2, "y")
        a.personID = marco.id; b.personID = marco.id
        let (folder, note) = try makeMeeting(lines: [a, b, line("Speaker 1", "meeting:A", 4, "z")])
        try RenameService(people: store).rename(speakerLabel: "Marco", to: "Paul", inMeetingFolder: folder, note: note)
        XCTAssertEqual(store.person(named: "Paul")?.samples, [[0, 1, 0], [0, 0, 1]])
        XCTAssertEqual(try lines(folder).map(\.speakerLabel), ["Paul", "J.", "Speaker 1"])
    }

    func testLearnAndNoteFailuresBothSurface() throws {
        try store.learn(name: "Marco", sample: [1, 0])
        let (folder, note) = try makeMeeting()
        try FileManager.default.removeItem(at: note)
        XCTAssertThrowsError(try RenameService(people: store).rename(speakerLabel: "Speaker 2", to: "Marco", inMeetingFolder: folder, note: note)) {
            guard case RenameError.notLearnedAndNoteFailed(PeopleStoreError.dimensionMismatch, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue($0.localizedDescription.contains("won't retry"))
        }
        XCTAssertEqual(try lines(folder).map(\.speakerLabel), ["Speaker 1", "Marco", "Speaker 1", "Marco"])
    }
}
