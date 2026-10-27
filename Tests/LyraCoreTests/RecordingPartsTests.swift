import XCTest
@testable import LyraCore

/// Recording again in a finished note: the finished part is filed under parts/N, the new part records in the
/// folder as usual, and its transcript is joined on after the earlier one.
final class RecordingPartsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func line(_ label: String, id: String? = nil, _ start: Double, _ end: Double, _ text: String,
                      known: Bool = false) -> TranscriptLine {
        var l = TranscriptLine(speakerLabel: label, speakerID: id, track: .mic, start: start, end: end, text: text)
        if known { l.personID = UUID(); l.nameSource = .knownVoice }
        return l
    }

    private func finishedMeeting(seconds: Double) throws -> Meeting {
        var meeting = Meeting(title: "Workshop", appName: "In person", startedAt: Date(timeIntervalSince1970: 0),
                              endedAt: Date(timeIntervalSince1970: 600))
        meeting.tracks = [TrackResult(kind: .mic, url: folder.appendingPathComponent("mic.caf"), seconds: seconds, peakLevel: 0.4, error: nil)]
        meeting.insightsDone = true
        meeting.afterMeetingDone = true
        meeting.expandedHashes = ["a"]
        try meeting.save(in: folder)
        for name in ["transcript.json", "speakers.json", "mic.m4a"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        return meeting
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }

    func testArchiveFilesTheFinishedPartAndReadiesTheFolder() throws {
        _ = try finishedMeeting(seconds: 300)
        _ = try RecordingParts.archive(folder: folder)
        XCTAssertTrue(exists("parts/1/transcript.json"))
        XCTAssertTrue(exists("parts/1/speakers.json"))
        XCTAssertTrue(exists("parts/1/mic.m4a"))
        XCTAssertFalse(exists("transcript.json"), "so a crash while recording the new part is recovered")
        let meeting = try Meeting.load(from: folder)
        XCTAssertEqual(meeting.earlierParts, 1)
        XCTAssertEqual(meeting.recordedBefore, 300)
        XCTAssertNil(meeting.tracks)
        XCTAssertNil(meeting.endedAt)
        XCTAssertNil(meeting.afterMeetingDone, "Claude refreshes the notes once the new part is written up")
        XCTAssertEqual(meeting.insightsDone, true, "the title isn't redone")
        XCTAssertEqual(meeting.expandedHashes, ["a"], "so untouched Expanded can be rewritten")
    }

    func testASecondResumeAddsTheSecondPartsLength() throws {
        var meeting = try finishedMeeting(seconds: 120)
        meeting.earlierParts = 1
        meeting.recordedBefore = 300
        try meeting.save(in: folder)
        _ = try RecordingParts.archive(folder: folder)
        XCTAssertTrue(exists("parts/2/transcript.json"))
        let saved = try Meeting.load(from: folder)
        XCTAssertEqual(saved.earlierParts, 2)
        XCTAssertEqual(saved.recordedBefore, 420)
    }

    func testRestorePutsEverythingBackWhenRecordingCantStart() throws {
        let before = try finishedMeeting(seconds: 300)
        let previous = try RecordingParts.archive(folder: folder)
        try RecordingParts.restore(folder: folder, previous: previous)
        XCTAssertTrue(exists("transcript.json"))
        XCTAssertTrue(exists("speakers.json"))
        XCTAssertTrue(exists("mic.m4a"))
        XCTAssertFalse(exists("parts/1"))
        let meeting = try Meeting.load(from: folder)
        XCTAssertEqual(meeting.earlierParts, before.earlierParts)
        XCTAssertEqual(meeting.endedAt, before.endedAt)
        XCTAssertEqual(meeting.afterMeetingDone, true)
    }

    func testJoinShiftsTheNewPartAndRenumbersPeopleLyraDoesntKnow() {
        let earlier = [line("Speaker 1", id: "mic:0", 2, 4, "hello"), line("Marco", id: "mic:1", 5, 8, "hi", known: true),
                       line("Speaker 2", id: "mic:2", 9, 10, "yes")]
        let earlierClusters = [SpeakerCluster(id: "mic:0", track: .mic, centroid: [1], speechSeconds: 2)]
        let new = [line("Speaker 1", id: "mic:0", 1, 3, "back again"), line("Marco", id: "mic:4", 4, 6, "right", known: true)]
        let newClusters = [SpeakerCluster(id: "mic:0", track: .mic, centroid: [0.5], speechSeconds: 2)]
        let joined = RecordingParts.join(earlier: earlier, earlierClusters: earlierClusters, new: new, newClusters: newClusters,
                                         offset: 300, part: 2)
        XCTAssertEqual(joined.lines.count, 5)
        XCTAssertEqual(Array(joined.lines.prefix(3)), earlier)
        XCTAssertEqual(joined.lines[3].speakerLabel, "Speaker 3", "not mixed up with the earlier Speaker 1")
        XCTAssertEqual(joined.lines[3].start, 301)
        XCTAssertEqual(joined.lines[3].end, 303)
        XCTAssertEqual(joined.lines[4].speakerLabel, "Marco")
        XCTAssertEqual(joined.lines[3].speakerID, "part2/mic:0")
        XCTAssertEqual(joined.clusters.map(\.id), ["mic:0", "part2/mic:0"])
    }
}
