import XCTest
@testable import LyraCore

final class TranscriptMergerTests: XCTestCase {
    private func line(_ label: String, _ track: TrackKind, _ s: Double, _ e: Double, _ t: String) -> TranscriptLine {
        TranscriptLine(speakerLabel: label, track: track, start: s, end: e, text: t)
    }

    func testDropsEcho() {
        let m = [line("meeting:0", .meeting, 10, 13, "we move it to friday afternoon")]
        let mic = [line("mic:0", .mic, 10.5, 13, "move it to friday afternoon")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).count, 1)
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).first?.track, .meeting)
    }

    func testKeepsRealMicSpeech() {
        let m = [line("meeting:0", .meeting, 10, 13, "we move it to friday afternoon")]
        let mic = [line("mic:0", .mic, 20, 21, "sounds good to me")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).map(\.text),
                       ["we move it to friday afternoon", "sounds good to me"])
    }

    func testLabelsInOrderOfAppearance() {
        let m = [line("meeting:3", .meeting, 5, 6, "hello there")]
        let mic = [line("mic:0", .mic, 1, 2, "first words"), line("mic:0", .mic, 9, 10, "later words")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).map(\.speakerLabel),
                       ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    func testTieMeetingBeforeMicAndSameRawIdsStaySeparateAcrossTracks() {
        let m = [line("meeting:0", .meeting, 1, 2, "alpha beta")]
        let mic = [line("mic:0", .mic, 1, 2, "gamma delta")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
    }

    func testDropsPartialEchoInsideLongMeetingLine() {
        let long = (1...40).map { "w\($0)" }.joined(separator: " ")
        let m = [line("meeting:0", .meeting, 0, 30, long)]
        let mic = [line("mic:0", .mic, 10, 14, "w5 w6 w7 w8 w9 w10 w11 w12")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).count, 1)
    }

    func testKeepsShortMicReply() {
        let m = [line("meeting:0", .meeting, 10, 11, "okay")]
        let mic = [line("mic:0", .mic, 10, 11, "okay")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).count, 2)
    }

    func testKeepsMicLineOutsideWindowBoundary() {
        let m = [line("meeting:0", .meeting, 10, 13, "we move it to friday afternoon")]
        let mic = [line("mic:0", .mic, 13.51, 17, "move it to friday afternoon")]  // echo pad is 0.5 s
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).count, 2)
    }

    /// A real reply right after a question shares stopwords ("think we should do") but isn't an echo.
    func testKeepsReplyThatReusesQuestionWords() {
        let m = [line("meeting:0", .meeting, 10, 15, "do you think we should do the friday shoot or is that too soon for you")]
        let mic = [line("mic:0", .mic, 15.5, 17, "yeah i think we should do that")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).count, 2)
    }

    // MARK: voice echo

    private func cl(_ id: String, _ degrees: Double) -> SpeakerCluster {
        let r = degrees * .pi / 180
        return SpeakerCluster(id: id, track: id.hasPrefix("mic") ? .mic : .meeting, centroid: [Float(cos(r)), Float(sin(r))], speechSeconds: 5)
    }
    private func raw(_ id: String, _ s: Double) -> TranscriptLine {
        TranscriptLine(speakerLabel: "Speaker 1", speakerID: id, track: id.hasPrefix("mic") ? .mic : .meeting, start: s, end: s + 1, text: id)
    }

    /// cos 31.8° ≈ 0.85: the call's voice leaking into the mic. Its lines and cluster go.
    func testDropsMicClusterThatSoundsLikeTheCall() {
        let out = TranscriptMerger.dropVoiceEcho(lines: [raw("meeting:S1", 0), raw("mic:S1", 1), raw("mic:S2", 2)],
                                                 clusters: [cl("meeting:S1", 0), cl("mic:S1", 31.8), cl("mic:S2", 90)],
                                                 people: [], policy: .init())
        XCTAssertEqual(out.lines.map(\.speakerID), ["meeting:S1", "mic:S2"])
        XCTAssertEqual(out.clusters.map(\.id), ["meeting:S1", "mic:S2"])
    }

    /// cos 72.5° ≈ 0.30: a different voice. Kept.
    func testKeepsMicClusterUnlikeTheCall() {
        let out = TranscriptMerger.dropVoiceEcho(lines: [raw("meeting:S1", 0), raw("mic:S1", 1)],
                                                 clusters: [cl("meeting:S1", 0), cl("mic:S1", 72.5)], people: [], policy: .init())
        XCTAssertEqual(out.lines.count, 2)
        XCTAssertEqual(out.clusters.count, 2)
    }

    /// Aidan's own voice is never echo, even when it sounds like a call voice.
    func testKeepsMicClusterOfAKnownPerson() {
        let aidan = Person(name: "Aidan", samples: [[Float(cos(31.8 * Double.pi / 180)), Float(sin(31.8 * Double.pi / 180))]])
        let out = TranscriptMerger.dropVoiceEcho(lines: [raw("meeting:S1", 0), raw("mic:S1", 1)],
                                                 clusters: [cl("meeting:S1", 0), cl("mic:S1", 31.8)], people: [aidan], policy: .init())
        XCTAssertEqual(out.lines.map(\.speakerID), ["meeting:S1", "mic:S1"])
        XCTAssertEqual(out.clusters.map(\.id), ["meeting:S1", "mic:S1"])
    }
}
