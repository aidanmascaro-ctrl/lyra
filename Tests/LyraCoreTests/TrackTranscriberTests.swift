import LyraCore
import XCTest

private struct FakeDiarizer: SpeakerDiarizing {
    let turns: [SpeakerTurn]
    func diarize(samples: [Float]) async throws -> [SpeakerTurn] { turns }
}

private actor SliceLog {
    var lengths: [Int] = []
    func add(_ n: Int) { lengths.append(n) }
}

private struct FakeTranscriber: SpeechTranscribing {
    let log = SliceLog()
    func transcribe(samples: [Float]) async throws -> String {
        await log.add(samples.count)
        return "text\(samples.count)"
    }
}

final class TrackTranscriberTests: XCTestCase {
    private let tenSeconds = [Float](repeating: 0, count: 160_000)

    private func run(_ turns: [SpeakerTurn], transcriber: FakeTranscriber = FakeTranscriber()) async throws -> [TranscriptLine] {
        try await TrackTranscriber(diarizer: FakeDiarizer(turns: turns), transcriber: transcriber)
            .run(samples: tenSeconds, track: .meeting)
    }

    func testOneLinePerTurn() async throws {
        let lines = try await run([
            SpeakerTurn(speaker: "A", start: 0, end: 2),
            SpeakerTurn(speaker: "B", start: 2, end: 4),
            SpeakerTurn(speaker: "A", start: 4, end: 6),
        ])
        XCTAssertEqual(lines.map(\.speakerLabel), ["meeting:A", "meeting:B", "meeting:A"])
        XCTAssertEqual(lines.map(\.text), ["text32000", "text32000", "text32000"])
        XCTAssertEqual(lines.map(\.track), [.meeting, .meeting, .meeting])
    }

    func testMergesSameSpeakerTurns() async throws {
        let lines = try await run([
            SpeakerTurn(speaker: "A", start: 0, end: 2),
            SpeakerTurn(speaker: "A", start: 2.2, end: 4),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.start, 0)
        XCTAssertEqual(lines.first?.end, 4)
    }

    func testSkipsBlips() async throws {
        let lines = try await run([SpeakerTurn(speaker: "A", start: 0, end: 0.2)])
        XCTAssertEqual(lines, [])
    }

    func testSliceUsesSampleRate() async throws {
        let fake = FakeTranscriber()
        _ = try await run([SpeakerTurn(speaker: "A", start: 1, end: 2)], transcriber: fake)
        let lengths = await fake.log.lengths
        XCTAssertEqual(lengths, [16_000])
    }

    func testMicTrackPrefix() async throws {
        let lines = try await TrackTranscriber(
            diarizer: FakeDiarizer(turns: [SpeakerTurn(speaker: "1", start: 0, end: 1)]),
            transcriber: FakeTranscriber()
        ).run(samples: tenSeconds, track: .mic)
        XCTAssertEqual(lines.map(\.speakerLabel), ["mic:1"])
    }
}
