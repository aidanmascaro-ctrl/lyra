import XCTest
@testable import LyraCore

final class VoiceMatcherTests: XCTestCase {
    private func person(_ v: [Float]) -> Person {
        Person(id: UUID(), name: "P", isOwner: false, samples: [v], updatedAt: Date())
    }
    private func unit(_ degrees: Double) -> [Float] {
        let r = degrees * .pi / 180
        return [Float(cos(r)), Float(sin(r))]
    }

    func testMatchAboveFloorAndMargin() {
        let a = person(unit(0)), b = person(unit(90))
        let m = VoiceMatcher.match(unit(10), people: [b, a])
        XCTAssertEqual(m?.personID, a.id)
        XCTAssertEqual(m?.similarity ?? 0, cos(10 * Double.pi / 180), accuracy: 1e-5)
    }

    func testNoMatchBelowFloor() {
        XCTAssertNil(VoiceMatcher.match(unit(80), people: [person(unit(0))]))
    }

    func testNoMatchWhenTwoPeopleTooClose() {
        XCTAssertNil(VoiceMatcher.match(unit(10), people: [person(unit(0)), person(unit(20))]))
    }

    func testNoPeopleNoMatch() {
        XCTAssertNil(VoiceMatcher.match(unit(0), people: []))
    }

    func testSkipsEmptyAndMismatchedPeopleAndBadCentroid() {
        let empty = Person(id: UUID(), name: "E", isOwner: false, samples: [], updatedAt: Date())
        let wrongDim = person([1, 0, 0])
        let good = person(unit(0))
        XCTAssertEqual(VoiceMatcher.match(unit(0), people: [empty, wrongDim, good])?.personID, good.id)
        XCTAssertNil(VoiceMatcher.match([], people: [good]))
        XCTAssertNil(VoiceMatcher.match([0, 0], people: [good]))
        XCTAssertNil(VoiceMatcher.match([.nan, 1], people: [good]))
    }
}
