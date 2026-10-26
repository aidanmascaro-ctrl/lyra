import LyraCore
import XCTest

private struct FakeDiarizer: SpeakerDiarizing {
    func diarize(samples: [Float]) async throws -> [SpeakerTurn] { [SpeakerTurn(speaker: "A", start: 0, end: 100)] }
}

/// The first sample says which track this is: 1 = meeting, 2 = mic.
private struct FakeTranscriber: SpeechTranscribing {
    func transcribe(samples: [Float]) async throws -> [TimedWord] {
        samples.first == 1
            ? [TimedWord(text: "hello", start: 0, end: 0.5), TimedWord(text: "from", start: 0.5, end: 1), TimedWord(text: "zoom", start: 1, end: 1.5)]
            : [TimedWord(text: "hi", start: 5, end: 5.5), TimedWord(text: "back", start: 5.5, end: 6)]
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

    private func track(_ kind: TrackKind, peak: Float = 0.3, error: String? = nil) throws -> TrackResult {
        let url = folder.appendingPathComponent("\(kind.rawValue).caf")
        try Data([kind == .meeting ? 1 : 2]).write(to: url)
        return TrackResult(kind: kind, url: url, seconds: 60, peakLevel: peak, error: error)
    }

    private func processor(convertFails: Bool = false) -> MeetingProcessor {
        MeetingProcessor(
            trackTranscriber: TrackTranscriber(diarizer: FakeDiarizer(), transcriber: FakeTranscriber()),
            loader: { url in [Float(try Data(contentsOf: url).first ?? 0)] },
            convert: { from, to in
                if convertFails { throw CocoaError(.fileWriteUnknown) }
                try Data(contentsOf: from).write(to: to)
            })
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
        XCTAssertEqual(try Meeting.load(from: folder).id, meeting.id)
        for kind in ["meeting", "mic"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(kind).m4a").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(kind).caf").path))
        }
    }

    func testSilentMeetingTrackStillWritesNote() async throws {
        _ = try await processor().process(meeting: meeting, tracks: [track(.meeting, peak: 0), track(.mic)], folder: folder, noteURL: note)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("Meeting audio was silent"))
        XCTAssertTrue(text.contains("Screen & System Audio Recording"))
    }

    func testMeetingTrackErrorWarns() async throws {
        _ = try await processor().process(meeting: meeting, tracks: [track(.meeting, error: "tap died"), track(.mic)], folder: folder, noteURL: note)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("Meeting audio was silent"))
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
        XCTAssertEqual(text.components(separatedBy: "Meeting audio was silent").count, 2)  // exactly once
    }

    func testRecoveryJobThrowsWithoutMeetingJSON() throws {
        try writeCAFs()
        XCTAssertThrowsError(try MeetingProcessor.recoveryJob(folder: folder, notesDir: notes))
    }
}
