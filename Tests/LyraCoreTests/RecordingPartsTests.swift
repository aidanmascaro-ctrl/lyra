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

    /// Tile names belong to the part they were seen in; slides stay where the note links them.
    func testOnScreenNamesFiledWithTheirPartSlidesStay() throws {
        _ = try finishedMeeting(seconds: 300)
        try OnScreenLog.save([OnScreenSample(t: 3, name: "Flo")], in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("slides"), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: folder.appendingPathComponent("slides.json"))
        _ = try RecordingParts.archive(folder: folder)
        XCTAssertTrue(exists("parts/1/onscreen.json"))
        XCTAssertFalse(exists("onscreen.json"))
        XCTAssertTrue(exists("slides"))
        XCTAssertTrue(exists("slides.json"))
    }

    /// The next part starts with no counts, so it warns (or not) on its own looks.
    func testCallWindowCountsFiledWithTheirPart() throws {
        _ = try finishedMeeting(seconds: 300)
        var health = CallWatchHealth()
        health.record(.seen)
        try health.save(in: folder)
        _ = try RecordingParts.archive(folder: folder)
        XCTAssertTrue(exists("parts/1/callwindow.json"))
        XCTAssertEqual(CallWatchHealth.load(from: folder), CallWatchHealth())
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

    func testArchiveThatFailsHalfwayPutsEverythingBack() throws {
        _ = try finishedMeeting(seconds: 300)
        let blocker = folder.appendingPathComponent("parts/1/mic.m4a")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("already here".utf8).write(to: blocker)
        XCTAssertThrowsError(try RecordingParts.archive(folder: folder))
        XCTAssertTrue(exists("transcript.json"))
        XCTAssertTrue(exists("speakers.json"))
        XCTAssertTrue(exists("mic.m4a"))
        XCTAssertNil(try Meeting.load(from: folder).earlierParts)
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

/// Resume after Quit: the part recorded before the quit was never written up, so its audio, on-screen log and a
/// copy of its meeting.json are filed under parts/N; writing up transcribes it there first.
final class UnwrittenPartTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }

    /// What Quit leaves: CAFs, meeting.json with its tracks and the quit mark, no transcript.
    private func quitMeeting(seconds: Double) throws -> Meeting {
        var meeting = Meeting(title: "Workshop", appName: "In person", startedAt: Date(timeIntervalSince1970: 0),
                              endedAt: Date(timeIntervalSince1970: 300))
        meeting.tracks = [TrackResult(kind: .mic, url: folder.appendingPathComponent("mic.caf"), seconds: seconds, peakLevel: 0.4, error: nil)]
        meeting.stoppedByQuit = true
        try meeting.save(in: folder)
        try Data([2]).write(to: folder.appendingPathComponent("mic.caf"))
        return meeting
    }

    func testArchiveFilesAnUnwrittenPartWithItsAudioAndMeeting() throws {
        _ = try quitMeeting(seconds: 300)
        try OnScreenLog.save([OnScreenSample(t: 3, name: "Flo")], in: folder)
        _ = try RecordingParts.archive(folder: folder)
        XCTAssertTrue(exists("parts/1/mic.caf"))
        XCTAssertTrue(exists("parts/1/onscreen.json"))
        XCTAssertTrue(exists("parts/1/meeting.json"), "its track levels and warnings, for writing it up later")
        XCTAssertFalse(exists("mic.caf"), "the new part records here")
        let meeting = try Meeting.load(from: folder)
        XCTAssertEqual(meeting.earlierParts, 1)
        XCTAssertEqual(meeting.recordedBefore, 300)
        XCTAssertNil(meeting.stoppedByQuit, "resumed: no longer offered")
        XCTAssertEqual(try Meeting.load(from: folder.appendingPathComponent("parts/1")).tracks?.first?.seconds, 300)
    }

    func testRestorePutsAnUnwrittenPartBack() throws {
        let before = try quitMeeting(seconds: 300)
        let previous = try RecordingParts.archive(folder: folder)
        try RecordingParts.restore(folder: folder, previous: previous)
        XCTAssertTrue(exists("mic.caf"))
        XCTAssertFalse(exists("parts"))
        let meeting = try Meeting.load(from: folder)
        XCTAssertNil(meeting.earlierParts)
        XCTAssertEqual(meeting.stoppedByQuit, true)
        XCTAssertEqual(meeting.id, before.id)
    }

    func testUnwrittenPartsListsOnlyPartsStillToTranscribe() throws {
        _ = try quitMeeting(seconds: 300)
        _ = try RecordingParts.archive(folder: folder)
        XCTAssertEqual(RecordingParts.unwritten(in: folder, upTo: 1), [1])
        try Data("[]".utf8).write(to: folder.appendingPathComponent("parts/1/transcript.json"))
        XCTAssertEqual(RecordingParts.unwritten(in: folder, upTo: 1), [])
    }
}

/// On launch: a recording Quit stopped is offered for Resume, not written up; a crash is written up as before.
final class ResumeOffersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-offers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String, quit: Bool) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meeting = Meeting(title: name, appName: "zoom.us", bundleID: "us.zoom.xos", startedAt: Date(timeIntervalSince1970: 0),
                              endedAt: Date(timeIntervalSince1970: 600))
        meeting.stoppedByQuit = quit ? true : nil
        try meeting.save(in: folder)
        try Data([2]).write(to: folder.appendingPathComponent("mic.caf"))
        return folder
    }

    func testQuitRecordingsAreOfferedCrashesAreRecovered() throws {
        let quit = try folder("2026-11-10 0900 — Quit", quit: true)
        let crash = try folder("2026-11-10 1000 — Crash", quit: false)
        let split = ResumeOffer.split(pending: [quit, crash])
        XCTAssertEqual(split.offers.map(\.folder), [quit])
        XCTAssertEqual(split.offers.first?.title, "2026-11-10 0900 — Quit")
        XCTAssertEqual(split.offers.first?.bundleID, "us.zoom.xos")
        XCTAssertEqual(split.offers.first?.stoppedAt, Date(timeIntervalSince1970: 600))
        XCTAssertEqual(split.recover, [crash])
    }

    func testAnUnreadableMeetingIsRecoveredNotOffered() throws {
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data([2]).write(to: broken.appendingPathComponent("mic.caf"))
        XCTAssertEqual(ResumeOffer.split(pending: [broken]).recover, [broken], "recovery reports why it can't be read")
    }

    func testMarkAndDecline() throws {
        let quit = try folder("q", quit: false)
        try ResumeOffer.markStoppedByQuit(folder: quit)
        XCTAssertEqual(try Meeting.load(from: quit).stoppedByQuit, true)
        XCTAssertTrue(ResumeOffer.isOffered(folder: quit))
        try ResumeOffer.decline(folder: quit)
        XCTAssertNil(try Meeting.load(from: quit).stoppedByQuit)
        XCTAssertFalse(ResumeOffer.isOffered(folder: quit))
    }

    func testOfferExpiresAfterFifteenMinutes() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(ResumeOffer.expired(offeredAt: start, now: start.addingTimeInterval(14 * 60)))
        XCTAssertTrue(ResumeOffer.expired(offeredAt: start, now: start.addingTimeInterval(15 * 60)))
    }
}
