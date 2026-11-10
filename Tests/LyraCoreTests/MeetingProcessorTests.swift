import LyraCore
import XCTest

/// The call's voice is [0, 1]; Aidan's mic voice is [1, 0]. Sample 4 is a mic hearing the call's voice
/// but transcribing it differently, so only the voice check can tell it is echo.
private struct FakeDiarizer: SpeakerDiarizing {
    func diarize(samples: [Float]) async throws -> Diarization {
        Diarization(turns: [SpeakerTurn(speaker: "A", start: 0, end: 100)],
                    centroids: ["A": samples.first == 2 ? [1, 0] : [0, 1]])
    }
}

/// The first sample says which track this is: 1 = meeting, 2 = mic, 3 = mic hearing only the call's echo, 4 = see FakeDiarizer.
private struct FakeTranscriber: SpeechTranscribing {
    func transcribe(samples: [Float]) async throws -> [TimedWord] {
        samples.first == 1 || samples.first == 3
            ? [TimedWord(text: "hello", start: 0, end: 0.5), TimedWord(text: "from", start: 0.5, end: 1), TimedWord(text: "zoom", start: 1, end: 1.5)]
            : [TimedWord(text: "hi", start: 1, end: 1.5), TimedWord(text: "back", start: 1.5, end: 2)]
    }
}

final class MeetingProcessorTests: XCTestCase {
    private var dir: URL!
    private var folder: URL!
    private var note: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-proc-\(UUID().uuidString)")
        folder = dir.appendingPathComponent("rec/2026-10-27 1000 — Call")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)
        note = dir.appendingPathComponent("notes/2026-10-27 1000 — Call.md")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func track(_ kind: TrackKind, peak: Float = 0.3, error: String? = nil, startOffset: Double? = nil) throws -> TrackResult {
        let url = folder.appendingPathComponent("\(kind.rawValue).caf")
        try Data([kind == .meeting ? 1 : 2]).write(to: url)
        var result = TrackResult(kind: kind, url: url, seconds: 60, peakLevel: peak, error: error)
        result.startOffset = startOffset
        return result
    }

    private func processor(convertFails: Bool = false, people: [Person] = []) -> MeetingProcessor {
        MeetingProcessor(
            trackTranscriber: TrackTranscriber(diarizer: FakeDiarizer(), transcriber: FakeTranscriber()),
            loader: { url in [Float(try Data(contentsOf: url).first ?? 0)] },
            convert: { from, to in
                if convertFails { throw CocoaError(.fileWriteUnknown) }
                try Data(contentsOf: from).write(to: to)
            },
            people: { people })
    }

    private let meeting = Meeting(title: "Call", appName: "zoom.us", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  endedAt: Date(timeIntervalSince1970: 1_800_000_600))

    func testWritesNoteAndMaster() async throws {
        let url = try await processor().process(meeting: meeting, tracks: [track(.meeting), track(.mic)], folder: folder, noteURL: note)
        XCTAssertEqual(url, note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(lines.map(\.text), ["hello from zoom", "hi back"])
        XCTAssertEqual(lines.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(lines.map(\.speakerID), ["meeting:A", "mic:A"])
        let speakers = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        XCTAssertEqual(speakers, [SpeakerCluster(id: "meeting:A", track: .meeting, centroid: [0, 1], speechSeconds: 100),
                                  SpeakerCluster(id: "mic:A", track: .mic, centroid: [1, 0], speechSeconds: 100)])
        XCTAssertEqual(try Meeting.load(from: folder).id, meeting.id)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("speakers.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)  // voice fingerprints, like people.json
        let section = try XCTUnwrap(NoteSections.transcriptBody(of: String(contentsOf: note, encoding: .utf8)))
        XCTAssertEqual(try Meeting.load(from: folder).transcriptSectionHash, NoteSections.hash(section))
        for kind in ["meeting", "mic"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(kind).m4a").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(kind).caf").path))
        }
    }

    /// An echo-only mic cluster is the remote voice leaking into the mic; it must not be saved as a mic speaker.
    func testEchoOnlyMicClusterNotSaved() async throws {
        let mic = try track(.mic)
        try Data([3]).write(to: mic.url)
        _ = try await processor().process(meeting: meeting, tracks: [track(.meeting), mic], folder: folder, noteURL: note)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(lines.map(\.speakerID), ["meeting:A"])
        let speakers = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        XCTAssertEqual(speakers.map(\.id), ["meeting:A"])
    }

    func testSilentMeetingTrackWarningIsNeutral() async throws {
        let chrome = Meeting(title: "Call", appName: "Google Chrome", startedAt: meeting.startedAt, endedAt: meeting.endedAt)
        _ = try await processor().process(meeting: chrome, tracks: [track(.meeting, peak: 0), track(.mic)], folder: folder, noteURL: note)
        let expected = "No sound came from Google Chrome during this meeting, so the transcript is from your microphone only. If other people spoke, check System Settings → Privacy & Security → Screen & System Audio Recording for Lyra."
        XCTAssertEqual(MeetingProcessor.noSoundWarning(appName: "Google Chrome"), expected)
        XCTAssertEqual(try Meeting.load(from: folder).warnings, [expected])
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains(expected))
    }

    func testMeetingTrackErrorWarns() async throws {
        _ = try await processor().process(meeting: meeting, tracks: [track(.meeting, error: "tap died"), track(.mic)], folder: folder, noteURL: note)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("No sound came from zoom.us"))
    }

    func testMicLinesShiftedByStartOffset() async throws {
        _ = try await processor().process(meeting: meeting, tracks: [track(.meeting, startOffset: 0), track(.mic, startOffset: 2.5)],
                                          folder: folder, noteURL: note)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        let mic = try XCTUnwrap(lines.first { $0.track == .mic })
        XCTAssertEqual(mic.start, 3.5, accuracy: 1e-9)
        XCTAssertEqual(mic.end, 4.5, accuracy: 1e-9)
        XCTAssertEqual(lines.first { $0.track == .meeting }?.start, 0)
    }

    func testOldTrackWithoutOffsetDecodes() throws {
        let json = #"{"kind":"mic","url":"file:///tmp/mic.caf","seconds":60,"peakLevel":0.4}"#
        let track = try JSONDecoder().decode(TrackResult.self, from: Data(json.utf8))
        XCTAssertNil(track.startOffset)
        XCTAssertEqual(track.kind, .mic)
    }

    func testStartOffsetsRelativeToEarliestTrack() throws {
        var meetingTrack = try track(.meeting), micTrack = try track(.mic), silent = try track(.mic)
        meetingTrack.firstFrameTime = 100.5
        micTrack.firstFrameTime = 98
        let out = TrackResult.withStartOffsets([meetingTrack, micTrack, silent])
        XCTAssertEqual(out.map(\.startOffset), [2.5, 0, nil])
    }

    func testMeetingTitleStripsBrowserSuffix() {
        XCTAssertEqual(Meeting.title(window: "Meet - abc-defg-hij - Google Chrome", appName: "Google Chrome"), "Meet - abc-defg-hij")
        XCTAssertEqual(Meeting.title(window: "Meet - abc - Google Chrome - Aidan", appName: "Google Chrome"), "Meet - abc")
        XCTAssertEqual(Meeting.title(window: "Zoom Call — Safari", appName: "Safari"), "Zoom Call")
        XCTAssertEqual(Meeting.title(window: "Teams - Microsoft Edge", appName: "Microsoft Edge"), "Teams")
        XCTAssertEqual(Meeting.title(window: " - Brave", appName: "Brave Browser"), "Brave Browser")
        XCTAssertEqual(Meeting.title(window: nil, appName: "zoom.us"), "zoom.us")
        XCTAssertEqual(Meeting.title(window: "Zoom Meeting", appName: "zoom.us"), "Zoom Meeting")
        // Only the meeting app's own suffix is stripped.
        XCTAssertEqual(Meeting.title(window: "Noah - Arc - Plan — Safari", appName: "Safari"), "Noah - Arc - Plan")
        XCTAssertEqual(Meeting.title(window: "Sync - Microsoft Edge", appName: "Google Chrome"), "Sync - Microsoft Edge")
        XCTAssertEqual(Meeting.title(window: "Standup - Brave", appName: "Brave Browser"), "Standup")
    }

    /// A known voice is named in transcript.json and the note; speakers.json still lists every kept cluster.
    func testNamesKnownVoice() async throws {
        let marco = Person(name: "Marco", samples: [[0, 1]])
        let aidan = Person(name: "Aidan", isOwner: true, samples: [[1, 0]])
        _ = try await processor(people: [marco, aidan]).process(meeting: meeting, tracks: [track(.meeting), track(.mic)], folder: folder, noteURL: note)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(lines.map(\.speakerLabel), ["Marco", "Aidan"])
        XCTAssertEqual(lines.map(\.personID), [marco.id, aidan.id])
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("**Marco** _(known voice)_ [00:00:00] hello from zoom"))
        let speakers = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        XCTAssertEqual(speakers.map(\.id), ["meeting:A", "mic:A"])
    }

    /// The call's voice on the mic, transcribed differently: the text filter keeps it, the voice check drops it.
    func testVoiceEchoMicClusterDropped() async throws {
        let mic = try track(.mic)
        try Data([4]).write(to: mic.url)
        _ = try await processor().process(meeting: meeting, tracks: [track(.meeting), mic], folder: folder, noteURL: note)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(lines.map(\.speakerID), ["meeting:A"])
        let speakers = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        XCTAssertEqual(speakers.map(\.id), ["meeting:A"])
    }

    /// Recording again after End: the new part's transcript goes on after the filed one, in the note too.
    func testResumedPartJoinsTheEarlierTranscript() async throws {
        let earlierLines = [TranscriptLine(speakerLabel: "Speaker 1", speakerID: "mic:A", track: .mic, start: 3, end: 5, text: "first part")]
        let part = folder.appendingPathComponent("parts/1")
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        try JSONEncoder().encode(earlierLines).write(to: part.appendingPathComponent("transcript.json"))
        try JSONEncoder().encode([SpeakerCluster(id: "mic:A", track: .mic, centroid: [1, 0], speechSeconds: 2)])
            .write(to: part.appendingPathComponent("speakers.json"))
        var resumed = meeting
        resumed.earlierParts = 1
        resumed.recordedBefore = 600
        _ = try await processor().process(meeting: resumed, tracks: [track(.mic)], folder: folder, noteURL: note)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(lines.map(\.text), ["first part", "hi back"])
        XCTAssertEqual(lines.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(lines[1].start, 601)
        let speakers = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        XCTAssertEqual(speakers.map(\.id), ["mic:A", "part2/mic:A"])
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("first part") && text.contains("hi back"))
    }

    /// End to end: write up part 1 into its note, Resume (file it away), write up part 2 — the note has both.
    func testResumedPartReachesTheExistingNote() async throws {
        var first = meeting
        first.notePath = note.path
        try MeetingProcessor.createSkeletonNote(for: first, recordingsFolder: folder, at: note)
        _ = try await processor().process(meeting: first, tracks: [track(.mic)], folder: folder, noteURL: note)
        _ = try RecordingParts.archive(folder: folder)
        let resumed = try Meeting.load(from: folder)
        _ = try await processor().process(meeting: resumed, tracks: [track(.mic)], folder: folder, noteURL: note)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "hi back").count - 1, 2, "both parts in the note's transcript")
        let section = try XCTUnwrap(NoteSections.transcriptBody(of: text))
        XCTAssertEqual(try Meeting.load(from: folder).transcriptSectionHash, NoteSections.hash(section))
    }

    /// Resume after Quit: the part before the quit was filed unwritten (audio only); writing up transcribes it in
    /// its own folder first, then joins the new part on after it.
    func testUnwrittenFiledPartIsTranscribedFirstThenJoined() async throws {
        var first = meeting
        first.notePath = note.path
        first.tracks = [try track(.mic)]
        first.stoppedByQuit = true
        try MeetingProcessor.createSkeletonNote(for: first, recordingsFolder: folder, at: note)
        try first.save(in: folder)
        _ = try RecordingParts.archive(folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("parts/1/mic.caf").path))
        let resumed = try Meeting.load(from: folder)
        _ = try await processor().process(meeting: resumed, tracks: [track(.mic)], folder: folder, noteURL: note)
        let part = folder.appendingPathComponent("parts/1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.appendingPathComponent("mic.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.appendingPathComponent("mic.caf").path), "kept until written up")
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(lines.map(\.text), ["hi back", "hi back"])
        XCTAssertEqual(lines[1].start, 61, "the new part starts after the 60 s recorded before the quit")
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "hi back").count - 1, 2, "both parts in the note")
    }

    /// Quit twice in one meeting: parts 1 and 2 are both unwritten; each is transcribed and joined in order.
    func testTwoUnwrittenPartsAreJoinedInOrder() async throws {
        var m = meeting
        m.notePath = note.path
        try MeetingProcessor.createSkeletonNote(for: m, recordingsFolder: folder, at: note)
        for _ in 0..<2 {
            m.tracks = [try track(.mic)]
            try m.save(in: folder)
            _ = try RecordingParts.archive(folder: folder)
            m = try Meeting.load(from: folder)
        }
        _ = try await processor().process(meeting: m, tracks: [track(.mic)], folder: folder, noteURL: note)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(lines.map(\.start), [1, 61, 121])
        XCTAssertEqual(lines.map(\.speakerLabel), ["Speaker 1", "Speaker 2", "Speaker 3"])
    }

    /// A transcript edited by hand in Obsidian is never replaced; the joined one is still saved in transcript.json.
    func testResumedPartLeavesAHandEditedTranscriptAlone() async throws {
        var first = meeting
        first.notePath = note.path
        try MeetingProcessor.createSkeletonNote(for: first, recordingsFolder: folder, at: note)
        _ = try await processor().process(meeting: first, tracks: [track(.mic)], folder: folder, noteURL: note)
        let edited = try String(contentsOf: note, encoding: .utf8).replacingOccurrences(of: "hi back", with: "hi back (fixed by hand)")
        try edited.write(to: note, atomically: true, encoding: .utf8)
        _ = try RecordingParts.archive(folder: folder)
        _ = try await processor().process(meeting: try Meeting.load(from: folder), tracks: [track(.mic)], folder: folder, noteURL: note)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("hi back (fixed by hand)"))
        XCTAssertEqual(text.components(separatedBy: "hi back").count - 1, 1)
        XCTAssertTrue(try Meeting.load(from: folder).warnings.contains(MeetingProcessor.editedTranscriptWarning))
    }

    func testMicOnlyMeeting() async throws {
        _ = try await processor().process(meeting: meeting, tracks: [track(.mic)], folder: folder, noteURL: note)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("hi back"))
        XCTAssertFalse(text.contains("[!warning]"))
    }

    func testConvertFailureKeepsCAFAndWarns() async throws {
        _ = try await processor(convertFails: true).process(meeting: meeting, tracks: [track(.mic)], folder: folder, noteURL: note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
        XCTAssertTrue(try Meeting.load(from: folder).warnings.contains { $0.contains("mic.caf") })
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("Couldn't compress mic.caf"))
    }

    func testNeverOverwritesExistingNote() async throws {
        try "mine".write(to: note, atomically: true, encoding: .utf8)
        do {
            _ = try await processor().process(meeting: meeting, tracks: [track(.mic)], folder: folder, noteURL: note)
            XCTFail("expected throw")
        } catch {}
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "mine")
        // Not marked processed, and the recording is untouched, so it can be retried.
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
    }

    // MARK: Note from the start of recording

    private var notesRoot: URL { dir.appendingPathComponent("notes") }

    func testNoteSkeletonExistsWhenRecordingStarts() throws {
        let recording = Meeting(title: "Call", appName: "zoom.us", startedAt: meeting.startedAt)
        try MeetingProcessor.createSkeletonNote(for: recording, recordingsFolder: folder, at: note)
        let doc = try NoteDocument.parse(String(contentsOf: note, encoding: .utf8))
        XCTAssertEqual(doc.front.lyraID, recording.id)
        XCTAssertEqual(doc.front.title, "Call")
        XCTAssertEqual(doc.front.recordings, folder)
        XCTAssertEqual([doc.myNotes, doc.expanded, doc.transcript], ["", "", ""])
        // Exclusive: never replaces a file already there.
        XCTAssertThrowsError(try MeetingProcessor.createSkeletonNote(for: recording, recordingsFolder: folder, at: note))
        XCTAssertEqual(try NoteDocument.parse(String(contentsOf: note, encoding: .utf8)).front.lyraID, recording.id)
    }

    func testProcessFillsTranscriptOfMovedSkeleton() async throws {
        try MeetingProcessor.createSkeletonNote(for: meeting, recordingsFolder: folder, at: note)
        let moved = notesRoot.appendingPathComponent("Northwind/Moved by Aidan.md")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: note, to: moved)

        let url = try await processor().process(meeting: meeting, tracks: [track(.meeting), track(.mic)], folder: folder, noteURL: note)
        XCTAssertEqual(url.standardizedFileURL, moved.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))  // no duplicate at the reserved path
        let text = try String(contentsOf: moved, encoding: .utf8)
        let doc = try NoteDocument.parse(text)
        XCTAssertTrue(doc.transcript.contains("hello from zoom"))
        XCTAssertEqual(doc.front.durationMin, 10)
        let saved = try Meeting.load(from: folder)
        XCTAssertEqual(saved.notePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, moved.resolvingSymlinksInPath())
        XCTAssertEqual(saved.transcriptSectionHash, NoteSections.transcriptBody(of: text).map(NoteSections.hash))
    }

    func testProcessKeepsTypedMyNotes() async throws {
        let quiet = Meeting(title: "Call", appName: "Google Chrome", startedAt: meeting.startedAt, endedAt: meeting.endedAt)
        try MeetingProcessor.createSkeletonNote(for: quiet, recordingsFolder: folder, at: note)
        let index = NoteIndex(notesRoot: notesRoot, vaultRoot: dir)
        let loaded = try index.load(quiet.id, hint: note)
        var typed = loaded.document
        typed.myNotes = "- pricing up **20%**\n  - <u>ask</u> about reels"
        typed.expanded = "kept as is"
        _ = try index.save(typed, over: loaded)

        _ = try await processor().process(meeting: quiet, tracks: [track(.meeting, peak: 0), track(.mic)], folder: folder, noteURL: note)
        let doc = try NoteDocument.parse(String(contentsOf: note, encoding: .utf8))
        XCTAssertEqual(doc.myNotes, typed.myNotes)
        XCTAssertEqual(doc.expanded, "kept as is")
        XCTAssertTrue(doc.transcript.contains("hi back"))
        XCTAssertEqual(doc.warnings, [MeetingProcessor.noSoundWarning(appName: "Google Chrome")])
    }

    func testPendingFoldersFindsUnprocessedCAFs() throws {
        let root = dir.appendingPathComponent("rec")
        let done = root.appendingPathComponent("done")
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        try Data().write(to: done.appendingPathComponent("mic.caf"))
        try Data().write(to: done.appendingPathComponent("transcript.json"))
        _ = try track(.mic)
        XCTAssertEqual(MeetingProcessor.pendingFolders(in: root).map(\.lastPathComponent), [folder.lastPathComponent])
    }
}

final class MeetingProcessorRecoveryTests: XCTestCase {
    private var dir: URL!
    private var folder: URL!
    private var notes: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-rec-\(UUID().uuidString)")
        folder = dir.appendingPathComponent("rec/2026-10-27 1000 — Call")
        notes = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let processor = MeetingProcessor(
        trackTranscriber: TrackTranscriber(diarizer: FakeDiarizer(), transcriber: FakeTranscriber()),
        loader: { url in [Float(try Data(contentsOf: url).first ?? 0)] },
        convert: { from, to in try Data(contentsOf: from).write(to: to) })

    private func writeCAFs() throws {
        try Data([1]).write(to: folder.appendingPathComponent("meeting.caf"))
        try Data([2]).write(to: folder.appendingPathComponent("mic.caf"))
    }

    func testCompletesWhenOurNoteAlreadyExists() async throws {
        let meeting = Meeting(title: "Call", appName: "zoom.us", startedAt: Date(), endedAt: Date())
        try writeCAFs()
        let note = notes.appendingPathComponent(folder.lastPathComponent + ".md")
        let original = Data("---\nlyra_id: \(meeting.id.uuidString)\n---\nedited by Aidan\n".utf8)
        try original.write(to: note)
        let job = try { try meeting.save(in: folder); return try MeetingProcessor.recoveryJob(folder: folder, notesDir: notes) }()
        _ = try await processor.process(meeting: job.meeting, tracks: job.tracks, folder: folder, noteURL: job.note)
        XCTAssertEqual(try Data(contentsOf: note), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
    }

    func testRecoveryUsesSavedTrackLevels() async throws {
        var meeting = Meeting(title: "Call", appName: "zoom.us", startedAt: Date(), endedAt: Date())
        meeting.tracks = [TrackResult(kind: .meeting, url: folder.appendingPathComponent("meeting.caf"), seconds: 60, peakLevel: 0, error: nil),
                          TrackResult(kind: .mic, url: folder.appendingPathComponent("mic.caf"), seconds: 60, peakLevel: 0.4, error: nil)]
        try meeting.save(in: folder)
        try writeCAFs()
        let job = try MeetingProcessor.recoveryJob(folder: folder, notesDir: notes)
        XCTAssertEqual(job.tracks.first { $0.kind == .meeting }?.peakLevel, 0)
        _ = try await processor.process(meeting: job.meeting, tracks: job.tracks, folder: folder, noteURL: job.note)
        let text = try String(contentsOf: job.note, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "No sound came from zoom.us").count, 2)  // exactly once
    }

    func testRecoveryJobThrowsWithoutMeetingJSON() throws {
        try writeCAFs()
        XCTAssertThrowsError(try MeetingProcessor.recoveryJob(folder: folder, notesDir: notes))
    }
}
