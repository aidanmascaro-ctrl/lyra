import XCTest
@testable import Lyra

final class FlowLayoutTests: XCTestCase {
    private let size = CGSize(width: 100, height: 20)

    func testItemsThatFitStayOnOneLine() {
        let frames = FlowLayout.frames(for: [size, size, size], width: 400, spacing: 6, lineSpacing: 6)
        XCTAssertEqual(frames.map(\.minX), [0, 106, 212])
        XCTAssertEqual(Set(frames.map(\.minY)), [0])
    }

    func testItemsWrapToTheNextLineInsteadOfOverflowing() {
        let frames = FlowLayout.frames(for: [size, size, size], width: 250, spacing: 6, lineSpacing: 8)
        XCTAssertEqual(frames.map(\.minX), [0, 106, 0])
        XCTAssertEqual(frames.map(\.minY), [0, 0, 28])
        XCTAssertTrue(frames.allSatisfy { $0.maxX <= 250 })
    }

    func testAnItemWiderThanTheLineIsNarrowedToFit() {
        let frames = FlowLayout.frames(for: [size, CGSize(width: 900, height: 20)], width: 300, spacing: 6, lineSpacing: 6)
        XCTAssertEqual(frames[1].minX, 0)
        XCTAssertEqual(frames[1].width, 300)
        XCTAssertEqual(frames[1].minY, 26)
    }

    func testShorterItemsAreCentredOnTheirLine() {
        let frames = FlowLayout.frames(for: [CGSize(width: 50, height: 24), CGSize(width: 50, height: 18)],
                                       width: 300, spacing: 6, lineSpacing: 6)
        XCTAssertEqual(frames[0].midY, frames[1].midY)
    }
}
