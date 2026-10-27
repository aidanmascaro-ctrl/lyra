import LyraCore
import XCTest

final class MeetingOverviewTests: XCTestCase {
    func testSpeakersInFirstAppearanceOrderWithSecondsAndSource() {
        func line(_ label: String, _ s: Double, _ e: Double, _ src: NameSource?) -> TranscriptLine {
            var l = TranscriptLine(speakerLabel: label, track: .meeting, start: s, end: e, text: "x")
            l.nameSource = src
            return l
        }
        let lines = [line("Speaker 1", 0, 2, nil), line("Aidan", 2, 5, .knownVoice), line("Speaker 1", 5, 6.5, nil),
                     line("Sam", 7, 8, .knownVoice), line("Sam", 8, 9, .setByAidan)]
        XCTAssertEqual(MeetingOverview.speakers(in: lines), [
            SpeakerSummary(label: "Speaker 1", source: nil, seconds: 3.5),
            SpeakerSummary(label: "Aidan", source: .knownVoice, seconds: 3),
            SpeakerSummary(label: "Sam", source: .setByAidan, seconds: 2),  // named by you wins
        ])
    }

    func testLastFolderIsNewestStartWithTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-last-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String, _ start: TimeInterval, transcript: Bool) throws -> URL {
            let f = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            try Meeting(title: name, appName: "Zoom", startedAt: Date(timeIntervalSince1970: start)).save(in: f)
            if transcript { try Data("[]".utf8).write(to: f.appendingPathComponent("transcript.json")) }
            return f
        }
        _ = try make("old", 100, transcript: true)
        let newest = try make("a-new", 300, transcript: true)  // name sorts first: order must come from startedAt
        _ = try make("unprocessed", 900, transcript: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("junk"), withIntermediateDirectories: true)
        XCTAssertEqual(MeetingOverview.lastFolder(in: root)?.lastPathComponent, newest.lastPathComponent)
        XCTAssertNil(MeetingOverview.lastFolder(in: root.appendingPathComponent("missing")))
    }
}
