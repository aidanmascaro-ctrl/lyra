import XCTest
@testable import LyraCore

final class OnScreenNamerTests: XCTestCase {
    private func unit(_ degrees: Double) -> [Float] {
        let r = degrees * .pi / 180
        return [Float(cos(r)), Float(sin(r))]
    }
    private func cluster(_ id: String, _ degrees: Double) -> SpeakerCluster {
        SpeakerCluster(id: id, track: id.hasPrefix("mic") ? .mic : .meeting, centroid: unit(degrees), speechSeconds: 10)
    }
    /// As SpeakerNamer leaves them: unknowns are "Speaker N" with their raw id.
    private func line(_ id: String, _ label: String, _ start: Double, _ end: Double) -> TranscriptLine {
        TranscriptLine(speakerLabel: label, speakerID: id, track: id.hasPrefix("mic") ? .mic : .meeting, start: start, end: end, text: "words")
    }
    /// One sample a second over [from, to).
    private func lit(_ name: String, _ from: Int, _ to: Int) -> [OnScreenSample] {
        (from..<to).map { OnScreenSample(t: Double($0), name: name) }
    }

    func testNamesAVoiceTheTileClearlyShows() {
        let lines = [line("meeting:S1", "Speaker 1", 0, 10)]
        let out = OnScreenNamer.name(lines: lines, clusters: [cluster("meeting:S1", 0)], samples: lit("Tomas Reed", 0, 10), people: [])
        XCTAssertEqual(out.lines[0].speakerLabel, "Tomas Reed")
        XCTAssertEqual(out.lines[0].nameSource, .onScreen)
        XCTAssertEqual(out.lines[0].confidence, 1)
        XCTAssertNil(out.lines[0].personID)  // a new person: their id only exists once learned
        XCTAssertEqual(out.learn.map(\.name), ["Tomas Reed"])
        XCTAssertEqual(out.learn.first?.clusters.map(\.id), ["meeting:S1"])
    }

    func testTooLittleEvidenceStaysUnknown() {
        let lines = [line("meeting:S1", "Speaker 1", 0, 10)]
        let out = OnScreenNamer.name(lines: lines, clusters: [cluster("meeting:S1", 0)], samples: lit("Tomas", 0, 5), people: [])
        XCTAssertEqual(out.lines[0].speakerLabel, "Speaker 1")
        XCTAssertTrue(out.learn.isEmpty)
    }

    func testSplitVoteStaysUnknown() {
        let lines = [line("meeting:S1", "Speaker 1", 0, 20)]
        let out = OnScreenNamer.name(lines: lines, clusters: [cluster("meeting:S1", 0)],
                                     samples: lit("Tomas", 1, 12) + lit("Flo", 12, 20), people: [])
        XCTAssertEqual(out.lines[0].speakerLabel, "Speaker 1")  // 11 of 19 is 58%: not sure
    }

    /// The ring lags the voice: the first half-second of each line doesn't count.
    func testLagSkipped() {
        let lines = [line("meeting:S1", "Speaker 1", 0, 3), line("meeting:S1", "Speaker 1", 4, 7), line("meeting:S1", "Speaker 1", 8, 11)]
        // A sample exactly at each line's start belongs to the previous speaker's ring.
        let samples = [0, 4, 8].map { OnScreenSample(t: Double($0), name: "Flo") } + [1, 2, 5, 6, 9, 10].map { OnScreenSample(t: Double($0), name: "Tomas") }
        let out = OnScreenNamer.name(lines: lines, clusters: [cluster("meeting:S1", 0)], samples: samples, people: [])
        XCTAssertEqual(Set(out.lines.map(\.speakerLabel)), ["Tomas"])
    }

    /// Two different voices under one tile is a room or a shared device: neither is named.
    func testSharedTileNamesNobody() {
        let lines = [line("meeting:S1", "Speaker 1", 0, 10), line("meeting:S2", "Speaker 2", 10, 20)]
        let out = OnScreenNamer.name(lines: lines, clusters: [cluster("meeting:S1", 0), cluster("meeting:S2", 90)],
                                     samples: lit("Tomas", 0, 20), people: [])
        XCTAssertEqual(out.lines.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertTrue(out.learn.isEmpty)
    }

    /// One voice the diarizer split in two (they sound alike) gets the name on both halves.
    func testSplitVoiceGetsTheNameTwice() {
        let lines = [line("meeting:S1", "Speaker 1", 0, 10), line("meeting:S2", "Speaker 2", 10, 20)]
        let out = OnScreenNamer.name(lines: lines, clusters: [cluster("meeting:S1", 0), cluster("meeting:S2", 20)],
                                     samples: lit("Tomas", 0, 20), people: [])
        XCTAssertEqual(out.lines.map(\.speakerLabel), ["Tomas", "Tomas"])
        XCTAssertEqual(out.learn.first?.clusters.map(\.id), ["meeting:S1", "meeting:S2"])
    }

    func testKnownVoiceIsNeverRenamed() {
        let marco = Person(name: "Marco", samples: [[1, 0]])
        var known = line("meeting:S1", "Marco", 0, 10)
        known.personID = marco.id
        known.nameSource = .knownVoice
        let out = OnScreenNamer.name(lines: [known], clusters: [cluster("meeting:S1", 0)], samples: lit("Tomas", 0, 10), people: [marco])
        XCTAssertEqual(out.lines[0].speakerLabel, "Marco")
        XCTAssertEqual(out.lines[0].nameSource, .knownVoice)
    }

    /// Aidan and the people in the room with him have no tile: the mic track is never named from the screen.
    func testMicTrackNotNamed() {
        let out = OnScreenNamer.name(lines: [line("mic:S1", "Speaker 1", 0, 10)], clusters: [cluster("mic:S1", 0)],
                                     samples: lit("Tomas", 0, 10), people: [])
        XCTAssertEqual(out.lines[0].speakerLabel, "Speaker 1")
    }

    func testExistingPersonIsJoined() {
        let tomas = Person(name: "Tomas Reed", samples: [[0, 1]])  // a voice that didn't match (another mic)
        let out = OnScreenNamer.name(lines: [line("meeting:S1", "Speaker 1", 0, 10)], clusters: [cluster("meeting:S1", 0)],
                                     samples: lit("tomas reed", 0, 10), people: [tomas])
        XCTAssertEqual(out.lines[0].speakerLabel, "Tomas Reed")
        XCTAssertEqual(out.lines[0].personID, tomas.id)
    }

    /// The tile names someone already heard by voice under another, different-sounding cluster: not sure, skip.
    func testNameAlreadyHeardAsAnotherVoiceSkipped() {
        let tomas = Person(name: "Tomas", samples: [[1, 0]])
        var known = line("meeting:S1", "Tomas", 0, 10)
        known.personID = tomas.id
        known.nameSource = .knownVoice
        let out = OnScreenNamer.name(lines: [known, line("meeting:S2", "Speaker 1", 10, 20)],
                                     clusters: [cluster("meeting:S1", 0), cluster("meeting:S2", 90)],
                                     samples: lit("Tomas", 0, 20), people: [tomas])
        XCTAssertEqual(out.lines[1].speakerLabel, "Speaker 1")
    }

    /// Aidan's own tile lights when he talks; a call voice is never given his name.
    func testOwnersNameNeverUsed() {
        let aidan = Person(name: "Aidan Mascaro", isOwner: true, samples: [[1, 0]])
        let out = OnScreenNamer.name(lines: [line("meeting:S1", "Speaker 1", 0, 10)], clusters: [cluster("meeting:S1", 90)],
                                     samples: lit("Aidan Mascaro", 0, 10), people: [aidan])
        XCTAssertEqual(out.lines[0].speakerLabel, "Speaker 1")
    }

    func testRemainingSpeakersRenumbered() {
        let lines = [line("meeting:S1", "Speaker 1", 0, 10), line("meeting:S2", "Speaker 2", 10, 20)]
        let out = OnScreenNamer.name(lines: lines, clusters: [cluster("meeting:S1", 0), cluster("meeting:S2", 90)],
                                     samples: lit("Tomas", 0, 10), people: [])
        XCTAssertEqual(out.lines.map(\.speakerLabel), ["Tomas", "Speaker 1"])
    }

    func testLogRoundTrips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-onscreen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(OnScreenLog.load(from: folder), [])
        try OnScreenLog.save(lit("Flo", 0, 3), in: folder)
        XCTAssertEqual(OnScreenLog.load(from: folder), lit("Flo", 0, 3))
    }
}
