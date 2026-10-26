import LyraCore
import XCTest

private struct FakeDiarizer: SpeakerDiarizing {
    let turns: [SpeakerTurn]
    var centroids: [String: [Float]] = [:]
    func diarize(samples: [Float]) async throws -> Diarization { Diarization(turns: turns, centroids: centroids) }
}

private struct FakeTranscriber: SpeechTranscribing {
    let words: [TimedWord]
    func transcribe(samples: [Float]) async throws -> [TimedWord] { words }
}

/// Fails the test if called: a track with no words must never reach the diarizer.
private struct ExplodingDiarizer: SpeakerDiarizing {
    func diarize(samples: [Float]) async throws -> Diarization {
        XCTFail("diarizer called for a track with no words")
        return Diarization(turns: [], centroids: [:])
    }
}

private func w(_ text: String, _ start: Double, _ end: Double) -> TimedWord { TimedWord(text: text, start: start, end: end) }
private func t(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn { SpeakerTurn(speaker: speaker, start: start, end: end) }

final class TrackTranscriberTests: XCTestCase {
    private func run(_ turns: [SpeakerTurn], _ words: [TimedWord], track: TrackKind = .meeting) async throws -> [TranscriptLine] {
        try await TrackTranscriber(diarizer: FakeDiarizer(turns: turns), transcriber: FakeTranscriber(words: words))
            .run(samples: [Float](repeating: 0, count: 160_000), track: track).lines
    }

    func testWordsAssignedByLargestOverlap() async throws {
        // "there" straddles the boundary but sits mostly in B's turn.
        let lines = try await run([t("A", 0, 2), t("B", 2, 4)], [w("hi", 0.2, 0.5), w("there", 1.9, 2.4), w("yes", 3, 3.3)])
        XCTAssertEqual(lines.map(\.speakerLabel), ["meeting:A", "meeting:B"])
        XCTAssertEqual(lines.map(\.text), ["hi", "there yes"])
        XCTAssertEqual(lines.map(\.track), [.meeting, .meeting])
    }

    func testWordInGapGoesToNearestTurn() async throws {
        let lines = try await run([t("A", 0, 1), t("B", 5, 6)], [w("could", 4.0, 4.3), w("we", 4.3, 4.5), w("go", 5.1, 5.4)])
        XCTAssertEqual(lines.map(\.speakerLabel), ["meeting:B"])
        XCTAssertEqual(lines.first?.text, "could we go")
        XCTAssertEqual(lines.first?.start, 4.0)
        XCTAssertEqual(lines.first?.end, 5.4)
    }

    func testNoTurnsIsSingleSpeakerZero() async throws {
        let lines = try await run([], [w("hello", 0, 0.4), w("world", 0.5, 0.9)], track: .mic)
        XCTAssertEqual(lines, [TranscriptLine(speakerLabel: "mic:0", speakerID: "mic:0", track: .mic, start: 0, end: 0.9, text: "hello world")])
    }

    func testSpeakerChangeSplitsLines() async throws {
        let lines = try await run([t("A", 0, 1), t("B", 1, 2), t("A", 2, 3)],
                                  [w("one", 0.1, 0.5), w("two", 1.1, 1.5), w("three", 2.1, 2.5)])
        XCTAssertEqual(lines.map(\.speakerLabel), ["meeting:A", "meeting:B", "meeting:A"])
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three"])
    }

    func testLongPauseSplitsLines() async throws {
        let lines = try await run([t("A", 0, 10)], [w("a", 0, 0.5), w("b", 1.9, 2.0), w("c", 3.6, 4.0)])
        XCTAssertEqual(lines.map(\.text), ["a b", "c"])  // 1.4 s gap joins, 1.6 s gap splits
        XCTAssertEqual(lines.map(\.start), [0, 3.6])
        XCTAssertEqual(lines.map(\.end), [2.0, 4.0])
    }

    func testNoWordsIsEmpty() async throws {
        let lines = try await run([t("A", 0, 2)], [])
        XCTAssertEqual(lines, [])
    }

    func testNoWordsNeverCallsDiarizer() async throws {
        let result = try await TrackTranscriber(diarizer: ExplodingDiarizer(), transcriber: FakeTranscriber(words: []))
            .run(samples: [Float](repeating: 0, count: 160_000), track: .meeting)
        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.clusters, [])
    }

    func testRunReturnsClusterPerSpeaker() async throws {
        // C has a centroid but no words land on it, so it gets no cluster.
        let diarizer = FakeDiarizer(turns: [t("A", 0, 2), t("B", 2, 3.5), t("A", 4, 5), t("C", 20, 21)],
                                    centroids: ["A": [1, 0], "B": [0, 1], "C": [0.6, 0.8]])
        let result = try await TrackTranscriber(diarizer: diarizer, transcriber: FakeTranscriber(words: [w("hi", 0.2, 0.5), w("yo", 2.2, 2.5), w("ok", 4.1, 4.4)]))
            .run(samples: [], track: .mic)
        XCTAssertEqual(result.clusters, [
            SpeakerCluster(id: "mic:A", track: .mic, centroid: [1, 0], speechSeconds: 3),
            SpeakerCluster(id: "mic:B", track: .mic, centroid: [0, 1], speechSeconds: 1.5),
        ])
        XCTAssertEqual(result.lines.map(\.speakerID), ["mic:A", "mic:B", "mic:A"])
    }

    func testSpeakerIDSurvivesMerge() async throws {
        let diarizer = FakeDiarizer(turns: [t("S1", 0, 2), t("S2", 2, 4)], centroids: [:])
        let lines = try await TrackTranscriber(diarizer: diarizer, transcriber: FakeTranscriber(words: [w("hi", 0.2, 0.5), w("yes", 3, 3.3)]))
            .run(samples: [], track: .meeting).lines
        let merged = TranscriptMerger.merge(meeting: lines, mic: [])
        XCTAssertEqual(merged.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(merged.map(\.speakerID), ["meeting:S1", "meeting:S2"])
    }

    /// A Phase 1 transcript.json line has none of the people fields.
    func testOldTranscriptLineDecodes() throws {
        let json = #"[{"end":2,"speakerLabel":"Speaker 1","start":1,"text":"hello","track":"mic"}]"#
        let line = try XCTUnwrap(JSONDecoder().decode([TranscriptLine].self, from: Data(json.utf8)).first)
        XCTAssertEqual(line, TranscriptLine(speakerLabel: "Speaker 1", track: .mic, start: 1, end: 2, text: "hello"))
        XCTAssertNil(line.speakerID); XCTAssertNil(line.personID); XCTAssertNil(line.nameSource); XCTAssertNil(line.confidence)
    }
}
