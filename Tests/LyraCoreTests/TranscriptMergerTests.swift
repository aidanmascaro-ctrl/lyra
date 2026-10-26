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
        let mic = [line("mic:0", .mic, 15.01, 17, "move it to friday afternoon")]
        XCTAssertEqual(TranscriptMerger.merge(meeting: m, mic: mic).count, 2)
    }
}
