import LyraCore
import XCTest

/// The call track is one voice, [0, 1], talking for ten seconds; the mic is Aidan, [1, 0].
private struct OneVoiceDiarizer: SpeakerDiarizing {
    func diarize(samples: [Float]) async throws -> Diarization {
        Diarization(turns: [SpeakerTurn(speaker: "A", start: 0, end: 100)], centroids: ["A": samples.first == 2 ? [1, 0] : [0, 1]])
    }
}

private struct TenSecondsTranscriber: SpeechTranscribing {
    func transcribe(samples: [Float]) async throws -> [TimedWord] {
        samples.first == 1 ? (0..<10).map { TimedWord(text: "word\($0)", start: Double($0), end: Double($0) + 0.9) } : []
    }
}

private final class Learned: @unchecked Sendable {
    var calls: [(String, [Float])] = []
    let person = Person(name: "Tomas Reed", samples: [[0, 1]])
}

final class MeetingProcessorScreenTests: XCTestCase {
    private var dir: URL!
    private var folder: URL!
    private var note: URL!
    private let meeting = Meeting(title: "Call", appName: "zoom.us", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  endedAt: Date(timeIntervalSince1970: 1_800_000_600))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-proc-screen-\(UUID().uuidString)")
        folder = dir.appendingPathComponent("rec/2026-10-27 1000 — Call")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)
        note = dir.appendingPathComponent("notes/2026-10-27 1000 — Call.md")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func meetingTrack() throws -> TrackResult {
        let url = folder.appendingPathComponent("meeting.caf")
        try Data([1]).write(to: url)
        return TrackResult(kind: .meeting, url: url, seconds: 60, peakLevel: 0.3, error: nil)
    }

    private func processor(learn: (@Sendable (String, [Float]) throws -> Person)?) -> MeetingProcessor {
        MeetingProcessor(trackTranscriber: TrackTranscriber(diarizer: OneVoiceDiarizer(), transcriber: TenSecondsTranscriber()),
                         loader: { url in [Float(try Data(contentsOf: url).first ?? 0)] },
                         convert: { from, to in try Data(contentsOf: from).write(to: to) }, learn: learn)
    }

    private func transcript() throws -> [TranscriptLine] {
        try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
    }

    func testNamesFromTheTilesAndLearnsTheVoice() async throws {
        try OnScreenLog.save((0..<10).map { OnScreenSample(t: Double($0), name: "Tomas Reed") }, in: folder)
        let learned = Learned()
        _ = try await processor(learn: { name, sample in learned.calls.append((name, sample)); return learned.person })
            .process(meeting: meeting, tracks: [meetingTrack()], folder: folder, noteURL: note)
        let lines = try transcript()
        XCTAssertEqual(lines.map(\.speakerLabel), ["Tomas Reed"])
        XCTAssertEqual(lines.map(\.nameSource), [.onScreen])
        XCTAssertEqual(lines.map(\.personID), [learned.person.id])
        XCTAssertEqual(learned.calls.map(\.0), ["Tomas Reed"])
        XCTAssertEqual(learned.calls.map(\.1), [[0, 1]])
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("**Tomas Reed** _(on screen)_"))
    }

    func testANameThatCantBeLearnedStaysAndWarns() async throws {
        try OnScreenLog.save((0..<10).map { OnScreenSample(t: Double($0), name: "Tomas Reed") }, in: folder)
        _ = try await processor(learn: { _, _ in throw PeopleStoreError.badSample })
            .process(meeting: meeting, tracks: [meetingTrack()], folder: folder, noteURL: note)
        XCTAssertEqual(try transcript().map(\.speakerLabel), ["Tomas Reed"])
        XCTAssertTrue(try Meeting.load(from: folder).warnings.contains { $0.contains("couldn't remember their voice") })
    }

    func testNoSamplesNoNames() async throws {
        _ = try await processor(learn: { _, _ in XCTFail("nothing to learn"); throw PeopleStoreError.badSample })
            .process(meeting: meeting, tracks: [meetingTrack()], folder: folder, noteURL: note)
        XCTAssertEqual(try transcript().map(\.speakerLabel), ["Speaker 1"])
    }
}
