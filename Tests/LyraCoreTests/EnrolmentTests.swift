import LyraCore
import XCTest

private struct FixedDiarizer: SpeakerDiarizing {
    let result: Diarization
    func diarize(samples: [Float]) async throws -> Diarization { result }
}

final class EnrolmentTests: XCTestCase {
    func testOwnerSampleFromLongestCluster() {
        // A speaks 3 + 4 = 7 s in two turns; B speaks 9 s in one. Total speech, not the longest turn, decides.
        let d = Diarization(
            turns: [SpeakerTurn(speaker: "A", start: 0, end: 3), SpeakerTurn(speaker: "B", start: 3, end: 12),
                    SpeakerTurn(speaker: "A", start: 12, end: 16), SpeakerTurn(speaker: "A", start: 16, end: 19)],
            centroids: ["A": [1, 0], "B": [0, 1]])
        XCTAssertEqual(Enrolment.ownerSample(from: d), [1, 0])  // A: 10 s beats B: 9 s
    }

    func testTooLittleSpeechReturnsNil() {
        let d = Diarization(turns: [SpeakerTurn(speaker: "A", start: 0, end: 7.9)], centroids: ["A": [1, 0]])
        XCTAssertNil(Enrolment.ownerSample(from: d))
        XCTAssertNil(Enrolment.ownerSample(from: Diarization(turns: [], centroids: [:])))
    }

    func testEnrolSavesOwnerAndAddsSampleOnRerun() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-enrol-\(UUID().uuidString)/people.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PeopleStore(fileURL: url)
        let diarizer = FixedDiarizer(result: Diarization(turns: [SpeakerTurn(speaker: "A", start: 0, end: 15)], centroids: ["A": [1, 0]]))
        let first = try await Enrolment.enrol(samples: [0], diarizer: diarizer, people: store)
        let second = try await Enrolment.enrol(samples: [0], diarizer: diarizer, people: store)
        XCTAssertTrue(first && second)
        let aidan = try XCTUnwrap(store.person(named: "Aidan"))
        XCTAssertTrue(aidan.isOwner)
        XCTAssertEqual(aidan.samples.count, 2)
    }

    func testEnrolWithTooLittleSpeechSavesNothing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-enrol-\(UUID().uuidString)/people.json")
        let store = PeopleStore(fileURL: url)
        let diarizer = FixedDiarizer(result: Diarization(turns: [SpeakerTurn(speaker: "A", start: 0, end: 2)], centroids: ["A": [1, 0]]))
        let saved = try await Enrolment.enrol(samples: [0], diarizer: diarizer, people: store)
        XCTAssertFalse(saved)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
