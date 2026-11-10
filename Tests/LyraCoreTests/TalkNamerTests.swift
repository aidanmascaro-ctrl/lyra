import XCTest
@testable import LyraCore

/// Answers by system prompt: the names call, the insights call and the expansion, in that order of use.
private final class Claude: ClaudeRunning, @unchecked Sendable {
    var names: Result<String, Error>
    let insights: String
    private let lock = NSLock()
    private(set) var systems: [String] = []
    private(set) var prompts: [String] = []
    /// Runs while Claude is "thinking" about names: Aidan doing something meanwhile.
    var duringNames: (() throws -> Void)?

    init(names: Result<String, Error>, insights: String = #"{"title": "Bakery check-in", "tags": [], "clients": [], "series": null, "summary": ""}"#) {
        self.names = names; self.insights = insights
    }

    func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { systems.append(system); prompts.append(prompt) }
        if system == Prompts.heardNamesSystem { try? duringNames?() }
        let reply: Result<String, Error> = system == Prompts.heardNamesSystem ? names
            : system == Prompts.insightsSystem ? .success(insights) : .success("@new Notes\n- done\n")
        return AsyncThrowingStream { c in
            switch reply {
            case .success(let text): c.yield(text); c.finish()
            case .failure(let error): c.finish(throwing: error)
            }
        }
    }
}

final class TalkNamerTests: XCTestCase {
    private var root: URL!
    private var notesRoot: URL!
    private var folder: URL!
    private var note: URL!
    private var meeting: Meeting!
    private var store: PeopleStore!

    private let priyaJSON = #"{"speakers": [{"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": ["I'm Priya"]}, {"speaker": "Speaker 2", "name": "Tomas", "sure": false, "evidence": ["Tomas, what about you?"]}]}"#

    private var standardLines: [TranscriptLine] {
        [
            TranscriptLine(speakerLabel: "Speaker 1", speakerID: "meeting:A", track: .meeting, start: 0, end: 3, text: "Hi, I'm Priya from the bakery."),
            TranscriptLine(speakerLabel: "Speaker 3", speakerID: "meeting:C", track: .meeting, start: 4, end: 6, text: "Tomas, what about you?"),
            TranscriptLine(speakerLabel: "Speaker 2", speakerID: "meeting:B", track: .meeting, start: 7, end: 9, text: "Landscaping, mostly."),
            TranscriptLine(speakerLabel: "Speaker 1", speakerID: "meeting:A", track: .meeting, start: 10, end: 12, text: "Same here."),
        ]
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-talk-\(UUID().uuidString)")
        notesRoot = root.appendingPathComponent("vault/Meetings")
        folder = root.appendingPathComponent("rec/2027-01-15 1000 — Zoom Meeting")
        for dir in [notesRoot!, folder!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        note = notesRoot.appendingPathComponent("2027-01-15 1000 — Zoom Meeting.md")
        meeting = Meeting(title: "Zoom Meeting", appName: "zoom.us", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_800_000_600))
        meeting.notePath = note.path
        meeting.transcriptSectionHash = NoteSections.hash(NoteRenderer.transcriptBody(lines: standardLines))
        try NoteRenderer.render(meeting: meeting, lines: standardLines, recordingsFolder: folder).write(to: note, atomically: true, encoding: .utf8)
        try meeting.save(in: folder)
        try JSONEncoder().encode(standardLines).write(to: folder.appendingPathComponent("transcript.json"))
        let speakers = [SpeakerCluster(id: "meeting:A", track: .meeting, centroid: [1, 0, 0], speechSeconds: 5),
                        SpeakerCluster(id: "meeting:B", track: .meeting, centroid: [0, 1, 0], speechSeconds: 2)]
        try JSONEncoder().encode(speakers).write(to: folder.appendingPathComponent("speakers.json"))
        store = PeopleStore(fileURL: root.appendingPathComponent("people.json"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func lines() throws -> [TranscriptLine] {
        try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
    }

    private func noteText() throws -> String { try String(contentsOf: note, encoding: .utf8) }

    // MARK: Running

    func testPutsSureNamesInTheTranscriptAndNoteAndKeepsSuggestions() async throws {
        let names = try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note).names

        XCTAssertEqual(names.map(\.name), ["Priya", "Tomas"])
        XCTAssertEqual(HeardNames.load(from: folder), names)
        XCTAssertEqual(try lines().map(\.speakerLabel), ["Priya", "Speaker 3", "Speaker 2", "Priya"])
        XCTAssertEqual(try lines()[0].nameSource, .heard)
        XCTAssertTrue(try noteText().contains("**Priya** _(from the talk)_ [00:00:00] Hi, I'm Priya"))
        XCTAssertEqual(try store.all(), [])  // no voice learned without Aidan's yes
        let saved = try Meeting.load(from: folder)
        XCTAssertEqual(saved.namesDone, true)
        XCTAssertEqual(saved.transcriptSectionHash, NoteSections.hash(NoteRenderer.transcriptBody(lines: try lines())))
    }

    func testLeavesANoteEditedByHandAlone() async throws {
        let edited = try noteText().replacingOccurrences(of: "Same here.", with: "Same here (edited).")
        try edited.write(to: note, atomically: true, encoding: .utf8)
        try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note)
        XCTAssertEqual(try noteText(), edited)
        XCTAssertEqual(try lines()[0].speakerLabel, "Priya")  // transcript.json still gets it; renaming asks later
    }

    func testAClaudeFailureWritesNothing() async throws {
        let before = try noteText()
        do {
            try await TalkNamer(claude: Claude(names: .failure(ClaudeError.failed("limit")))).run(folder: folder, note: note)
            XCTFail("expected throw")
        } catch {}
        XCTAssertEqual(try lines(), standardLines)
        XCTAssertEqual(try noteText(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(HeardNames.fileName).path))
        XCTAssertNil(try Meeting.load(from: folder).namesDone)
    }

    func testARenameMadeWhileClaudeAnswersIsKept() async throws {
        let claude = Claude(names: .success(priyaJSON))
        let (store, folder, note) = (store!, folder!, note!)
        claude.duringNames = {  // Aidan names Speaker 1 "Bob" while Claude is still answering
            try RenameService(people: store).rename(speakerLabel: "Speaker 1", to: "Bob", inMeetingFolder: folder, note: note)
        }
        let outcome = try await TalkNamer(claude: claude).run(folder: folder, note: note)

        XCTAssertEqual(outcome.note, .done)
        XCTAssertEqual(try lines().map(\.speakerLabel), ["Bob", "Speaker 3", "Speaker 2", "Bob"])
        XCTAssertEqual(try lines()[0].nameSource, .setByAidan)
        XCTAssertTrue(try noteText().contains("**Bob** [00:00:00]"))
        XCTAssertFalse(try noteText().contains("Priya**"))
    }

    func testReportsAHandEditedNote() async throws {
        try noteText().replacingOccurrences(of: "Same here.", with: "Same here (edited).").write(to: note, atomically: true, encoding: .utf8)
        let outcome = try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note)
        XCTAssertEqual(outcome.note, .needsConfirmation)
    }

    func testAnUnreadableNamesFileIsNeverWrittenOver() async throws {
        let file = folder.appendingPathComponent(HeardNames.fileName)
        try Data("not json".utf8).write(to: file)
        do {
            try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note)
            XCTFail("expected throw")
        } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
        XCTAssertEqual(try lines(), standardLines)
    }

    func testAResumedRecordingKeepsOnlyTheNamesAlreadyIn() async throws {
        try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note)
        // The new part's first unknown voice is labelled "Speaker 2" too: the old "Tomas?" must not land on it.
        try TalkNamer.afterJoin(folder: folder, lines: try lines())
        XCTAssertEqual(HeardNames.load(from: folder).map(\.name), ["Priya"])
    }

    func testARejectionSurvivesAResume() async throws {
        try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note)
        let tomas = try XCTUnwrap(HeardNames.load(from: folder).first { $0.name == "Tomas" })
        try TalkNamer.reject(tomas, folder: folder, note: note)
        try TalkNamer.afterJoin(folder: folder, lines: try lines())
        XCTAssertEqual(HeardNames.load(from: folder).first { $0.name == "Tomas" }?.rejected, true)
    }

    func testNotThemAfterAResumeNeverSharesALabel() async throws {
        try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note)
        // A resumed part's new unknown voice has taken the label "Speaker 1" that Priya had before.
        var joined = try lines()
        joined.append(TranscriptLine(speakerLabel: "Speaker 1", speakerID: "part2/meeting:A", track: .meeting, start: 20, end: 22, text: "New voice."))
        try JSONEncoder().encode(joined).write(to: folder.appendingPathComponent("transcript.json"))
        let priya = try XCTUnwrap(HeardNames.load(from: folder).first { $0.name == "Priya" })

        try TalkNamer.reject(priya, folder: folder, note: note)
        XCTAssertEqual(try lines().map(\.speakerLabel), ["Speaker 4", "Speaker 3", "Speaker 2", "Speaker 4", "Speaker 1"])
    }

    // MARK: Not them

    func testNotThemPutsTheSpeakerBackAndARerunDoesNotBringItBack() async throws {
        let namer = TalkNamer(claude: Claude(names: .success(priyaJSON)))
        let names = try await namer.run(folder: folder, note: note).names

        XCTAssertEqual(try TalkNamer.reject(names[0], folder: folder, note: note), .done)
        XCTAssertEqual(try lines().map(\.speakerLabel), ["Speaker 1", "Speaker 3", "Speaker 2", "Speaker 1"])
        XCTAssertNil(try lines()[0].nameSource)
        XCTAssertFalse(try noteText().contains("Priya**"))

        try await namer.run(folder: folder, note: note)  // Suggest names again
        XCTAssertEqual(try lines()[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(HeardNames.load(from: folder).first { $0.name == "Priya" }?.rejected, true)
    }

    func testNotThemOnASuggestionOnlyHidesIt() async throws {
        let names = try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note).names
        let tomas = try XCTUnwrap(names.first { $0.name == "Tomas" })
        let before = try lines()
        try TalkNamer.reject(tomas, folder: folder, note: note)
        XCTAssertEqual(try lines(), before)
        XCTAssertNil(HeardNames.entry(for: "Speaker 2", source: nil, in: HeardNames.load(from: folder)))
    }

    // MARK: Yes, that's them

    func testSayingTheHeardNameAgainConfirmsItAndLearnsTheVoice() async throws {
        try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note)
        try RenameService(people: store).rename(speakerLabel: "Priya", to: "Priya", inMeetingFolder: folder, note: note)

        let priya = try XCTUnwrap(store.person(named: "Priya"))
        XCTAssertEqual(try lines().filter { $0.speakerLabel == "Priya" }.map(\.nameSource), [.setByAidan, .setByAidan])
        XCTAssertEqual(try lines()[0].personID, priya.id)
        XCTAssertTrue(try noteText().contains("**Priya** [00:00:00]"))  // no "from the talk" badge any more
    }

    func testPillEntries() async throws {
        let names = try await TalkNamer(claude: Claude(names: .success(priyaJSON))).run(folder: folder, note: note).names
        XCTAssertEqual(HeardNames.entry(for: "Priya", source: .heard, in: names)?.speaker, "Speaker 1")
        XCTAssertEqual(HeardNames.entry(for: "Speaker 2", source: nil, in: names)?.name, "Tomas")
        XCTAssertNil(HeardNames.entry(for: "Speaker 3", source: nil, in: names))
        XCTAssertNil(HeardNames.entry(for: "Priya", source: .setByAidan, in: names))
    }

    // MARK: After the meeting

    private func afterMeeting(_ claude: Claude) -> AfterMeeting {
        let index = NoteIndex(notesRoot: notesRoot, vaultRoot: notesRoot.deletingLastPathComponent())
        return AfterMeeting(index: index, claude: claude, expander: Expander(claude: claude),
                            vaultRoot: notesRoot.deletingLastPathComponent(), talkNamer: TalkNamer(claude: claude))
    }

    func testAfterTheMeetingNamesComeBeforeTheTitleAndNotes() async throws {
        let claude = Claude(names: .success(priyaJSON))
        try await afterMeeting(claude).run(folder: folder)
        XCTAssertEqual(claude.systems.first, Prompts.heardNamesSystem)
        let insightsPrompt = try XCTUnwrap(zip(claude.systems, claude.prompts).first { $0.0 == Prompts.insightsSystem }?.1)
        XCTAssertTrue(insightsPrompt.contains("Priya: Hi, I'm Priya"))
        XCTAssertEqual(try Meeting.load(from: folder).afterMeetingDone, true)
    }

    func testAfterTheMeetingANamingFailureIsRecordedAndTheRestGoesOn() async throws {
        let claude = Claude(names: .success("no idea"))
        try await afterMeeting(claude).run(folder: folder)
        let saved = try Meeting.load(from: folder)
        XCTAssertEqual(saved.namesError, HeardNamesError.noJSON.localizedDescription)
        XCTAssertNil(saved.namesDone)
        XCTAssertEqual(saved.insightsDone, true)
        XCTAssertEqual(saved.afterMeetingDone, true)
    }

    func testAfterTheMeetingNamesOnlyOnce() async throws {
        let claude = Claude(names: .success(priyaJSON))
        try await afterMeeting(claude).run(folder: folder)
        try await afterMeeting(claude).run(folder: folder)  // Retry
        XCTAssertEqual(claude.systems.filter { $0 == Prompts.heardNamesSystem }.count, 1)
    }
}
