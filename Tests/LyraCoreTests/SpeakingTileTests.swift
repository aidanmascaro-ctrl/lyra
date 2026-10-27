import XCTest
@testable import LyraCore

final class SpeakingTileTests: XCTestCase {
    /// A dark call window: a 2×2 grid of grey tiles.
    private func gallery(width: Int = 400, height: Int = 240) -> PixelFrame {
        var frame = PixelFrame(width: width, height: height, fill: (30, 30, 30))
        for (x, y) in [(10, 10), (205, 10), (10, 125), (205, 125)] {
            frame.fill(PixelRect(x: x, y: y, width: 185, height: 105), (70, 70, 70))
        }
        return frame
    }

    func testFindsTheLitTile() {
        var frame = gallery()
        frame.outline(PixelRect(x: 205, y: 125, width: 185, height: 105), (35, 217, 89), thickness: 2)  // Zoom green
        let rings = SpeakingTile.find(in: frame)
        XCTAssertEqual(rings.count, 1)
        let r = rings[0]
        XCTAssertEqual(r.x, 205, accuracy: 1)
        XCTAssertEqual(r.y, 125, accuracy: 1)
        XCTAssertEqual(r.width, 185, accuracy: 2)
        XCTAssertEqual(r.height, 105, accuracy: 2)
    }

    func testAnyHueCounts() {
        for colour: (UInt8, UInt8, UInt8) in [(138, 180, 248), (127, 133, 245), (35, 165, 90)] {  // Meet, Teams, Discord
            var frame = gallery()
            frame.outline(PixelRect(x: 10, y: 10, width: 185, height: 105), colour, thickness: 3)
            XCTAssertEqual(SpeakingTile.find(in: frame).count, 1, "\(colour)")
        }
    }

    func testNoRingNoTile() {
        XCTAssertEqual(SpeakingTile.find(in: gallery()), [])
    }

    /// A green shirt or a filled button is a block of colour, not a ring.
    func testFilledColourIsNotARing() {
        var frame = gallery()
        frame.fill(PixelRect(x: 60, y: 40, width: 90, height: 60), (35, 217, 89))
        XCTAssertEqual(SpeakingTile.find(in: frame), [])
    }

    /// Two sides of a box (an underline and a bar) are not a ring.
    func testOpenShapeIsNotARing() {
        var frame = gallery()
        frame.fill(PixelRect(x: 205, y: 228, width: 185, height: 2), (35, 217, 89))
        frame.fill(PixelRect(x: 205, y: 125, width: 2, height: 105), (35, 217, 89))
        XCTAssertEqual(SpeakingTile.find(in: frame), [])
    }

    /// Too small to be a tile: an icon's outline.
    func testTinyRingIgnored() {
        var frame = gallery()
        frame.outline(PixelRect(x: 30, y: 30, width: 12, height: 12), (35, 217, 89), thickness: 1)
        XCTAssertEqual(SpeakingTile.find(in: frame), [])
    }

    /// Grey and white outlines (the window's own borders, a selected tile in grey) are not a lit tile.
    func testGreyOutlineIgnored() {
        var frame = gallery()
        frame.outline(PixelRect(x: 205, y: 125, width: 185, height: 105), (230, 230, 230), thickness: 2)
        XCTAssertEqual(SpeakingTile.find(in: frame), [])
    }

    func testNormalisedRect() {
        var frame = gallery()
        frame.outline(PixelRect(x: 200, y: 120, width: 100, height: 60), (35, 217, 89), thickness: 2)
        let n = SpeakingTile.find(in: frame)[0].normalised(in: frame)
        XCTAssertEqual(n.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(n.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(n.width, 0.25, accuracy: 0.01)
        XCTAssertEqual(n.height, 0.25, accuracy: 0.01)
    }
}

final class TileNameTests: XCTestCase {
    func testCleansLabels() {
        XCTAssertEqual(TileName.clean("Tomas Reed (Host)"), "Tomas Reed")
        XCTAssertEqual(TileName.clean("  Marco Diaz | Acme Pty Ltd "), "Marco Diaz")
        XCTAssertEqual(TileName.clean("Sarah O'Neil (she/her)"), "Sarah O'Neil")
        XCTAssertEqual(TileName.clean("Mary-Jane van Dyk"), "Mary-Jane van Dyk")
        XCTAssertEqual(TileName.clean("Flo"), "Flo")
    }

    func testRefusesDevicesRoomsAndJunk() {
        for text in ["Aidan's iPhone", "MacBook Pro", "Galaxy S21", "Boardroom", "Zoom Room 3", "Presentation",
                     "Guest", "tomas@acme.com", "Participant 4", "You", "is presenting", "12:04", "Mute",
                     "Ab", "One Two Three Four Five", "Elm Park Conference Room", "Recording", ""] {
            XCTAssertNil(TileName.clean(text), text)
        }
    }

    func testPicksTheLowestNameInTheTile() {
        // Top of the tile first; the name label sits at the bottom.
        let lines: [(text: String, bottom: Double)] = [("Q3 Pricing", 0.2), ("Tomas Reed", 0.92), ("Mute", 0.95)]
        XCTAssertEqual(TileName.pick(lines), "Tomas Reed")
        XCTAssertNil(TileName.pick([("Recording", 0.9)]))
    }
}
