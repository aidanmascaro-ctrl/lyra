import XCTest
@testable import LyraCore

final class SpeakerNamerTests: XCTestCase {
    private func unit(_ degrees: Double) -> [Float] {
        let r = degrees * .pi / 180
        return [Float(cos(r)), Float(sin(r))]
    }
    private func cluster(_ id: String, _ degrees: Double) -> SpeakerCluster {
        SpeakerCluster(id: id, track: id.hasPrefix("mic") ? .mic : .meeting, centroid: unit(degrees), speechSeconds: 10)
    }
    /// Lines as the merger hands them over: already "Speaker N", raw id in `speakerID`.
    private func line(_ id: String, _ start: Double, _ end: Double, _ text: String, label: String = "Speaker 9") -> TranscriptLine {
        TranscriptLine(speakerLabel: label, speakerID: id, track: id.hasPrefix("mic") ? .mic : .meeting, start: start, end: end, text: text)
    }

    private let marco = Person(name: "Marco", samples: [[1, 0]])

    /// Review Focus 1: Aidan's voice split into two clusters on one track is one person, and his lines join up.
    func testTwoClustersSamePersonOneName() {
        let out = SpeakerNamer.name(
            lines: [line("mic:0", 0, 2, "so the plan"), line("mic:1", 2.5, 4, "is Friday"), line("mic:1", 10, 11, "later")],
            clusters: [cluster("mic:0", 5), cluster("mic:1", 15)], people: [marco], policy: .init())
        XCTAssertEqual(out.map(\.text), ["so the plan is Friday", "later"])  // 0.5 s gap joins; 6 s gap doesn't
        XCTAssertEqual(out.map(\.speakerLabel), ["Marco", "Marco"])
        XCTAssertEqual(out.map(\.personID), [marco.id, marco.id])
        XCTAssertEqual(out.map(\.nameSource), [.knownVoice, .knownVoice])
        XCTAssertEqual(out[0].speakerID, "mic:0")  // the first line's raw id survives the join
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[0].end, 4)
        XCTAssertEqual(out[0].confidence ?? 0, cos(15 * Double.pi / 180), accuracy: 1e-5)  // the weaker of the two
        XCTAssertEqual(out[1].confidence ?? 0, cos(15 * Double.pi / 180), accuracy: 1e-5)
    }

    /// Review Focus 2: the same person heard on both tracks gets one name, but lines never join across tracks.
    func testSamePersonAcrossTracks() {
        let out = SpeakerNamer.name(
            lines: [line("meeting:S1", 0, 2, "hello"), line("mic:0", 2.2, 3, "hello again")],
            clusters: [cluster("meeting:S1", 0), cluster("mic:0", 10)], people: [marco], policy: .init())
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.speakerLabel), ["Marco", "Marco"])
        XCTAssertEqual(out.map(\.personID), [marco.id, marco.id])
        XCTAssertEqual(out.map(\.speakerID), ["meeting:S1", "mic:0"])
    }

    /// Unknowns are renumbered by first appearance, skipping named people; a line with no cluster is an unknown too.
    func testUnknownsNumberedSkippingNamed() {
        let out = SpeakerNamer.name(
            lines: [line("meeting:S1", 0, 1, "a", label: "Speaker 1"),
                    line("meeting:S2", 2, 3, "b", label: "Speaker 2"),
                    line("mic:0", 4, 5, "c", label: "Speaker 3"),
                    line("meeting:S1", 6, 7, "d", label: "Speaker 1"),
                    line("meeting:S2", 8, 9, "e", label: "Speaker 2")],
            clusters: [cluster("meeting:S1", 0), cluster("meeting:S2", 90)], people: [marco], policy: .init())
        XCTAssertEqual(out.map(\.speakerLabel), ["Marco", "Speaker 1", "Speaker 2", "Marco", "Speaker 1"])
        XCTAssertEqual(out.map(\.personID), [marco.id, nil, nil, marco.id, nil])
        XCTAssertEqual(out.map(\.nameSource), [.knownVoice, nil, nil, .knownVoice, nil])
    }

    func testLowConfidenceStaysSpeakerN() {
        let lines = [line("meeting:S1", 0, 1, "a"), line("meeting:S2", 2, 3, "b")]
        let clusters = [cluster("meeting:S1", -60), cluster("meeting:S2", 10)]
        // -60° is cos 0.5 to Marco (and further from Jürgen): under the 0.60 floor. 10° from Marco but only 5° away from a second person: margin too small.
        let marco2 = Person(name: "Jürgen", samples: [unit(15)])
        let out = SpeakerNamer.name(lines: lines, clusters: clusters, people: [marco, marco2], policy: .init())
        XCTAssertEqual(out.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(out.map(\.personID), [nil, nil])
        XCTAssertEqual(out.map(\.confidence), [nil, nil])
        // No people at all: same result, nothing is ever named.
        XCTAssertEqual(SpeakerNamer.name(lines: lines, clusters: clusters, people: [], policy: .init()).map(\.speakerLabel),
                       ["Speaker 1", "Speaker 2"])
    }
}
