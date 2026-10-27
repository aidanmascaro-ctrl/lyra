import XCTest
@testable import LyraCore

final class SlideWatcherTests: XCTestCase {
    /// A "slide": dark window with a light page whose bars (lines of text) depend on `n`.
    private func slide(_ n: Int, noise: UInt8 = 0) -> Thumbnail {
        var f = PixelFrame(width: 320, height: 180, fill: (20 + noise, 20, 20))
        f.fill(PixelRect(x: 20, y: 10, width: 280, height: 160), (240, 240, 240))
        for i in 0..<(3 + n % 4) {
            f.fill(PixelRect(x: 40, y: 30 + i * 30, width: 60 + (n * 37 + i * 53) % 200, height: 12), (30, 30, 30))
        }
        return Thumbnail(frame: f)
    }

    private let slideText = ["Q3 pricing review", "Revenue is up twelve percent on last year", "Next steps for the team"]

    /// Feeds the same picture until the watcher asks to check it, at most `seconds` times.
    private func showUntilCandidate(_ w: inout SlideWatcher, _ t: Thumbnail, seconds: Int = 5) -> Bool {
        for _ in 0..<seconds where w.look(t) { return true }
        return false
    }

    func testAStillNewSlideIsACandidateOnce() {
        var w = SlideWatcher()
        XCTAssertFalse(w.look(slide(1)))
        XCTAssertFalse(w.look(slide(1)))
        XCTAssertTrue(w.look(slide(1)), "still for 2 s")
        XCTAssertTrue(w.decide(slide(1), text: slideText, tileNames: []))
        XCTAssertFalse(showUntilCandidate(&w, slide(1), seconds: 30), "never asked again while it stays up")
    }

    func testTransitionsAreNotCandidates() {
        var w = SlideWatcher()
        for n in 0..<10 { XCTAssertFalse(w.look(slide(n)), "changes every second") }
    }

    func testNextSlideIsSaved() {
        var w = SlideWatcher()
        XCTAssertTrue(showUntilCandidate(&w, slide(1)))
        XCTAssertTrue(w.decide(slide(1), text: slideText, tileNames: []))
        XCTAssertTrue(showUntilCandidate(&w, slide(2)))
        XCTAssertTrue(w.decide(slide(2), text: slideText, tileNames: []))
    }

    /// The presenter flips back to slide 1: it was saved already.
    func testFlippingBackIsNotADuplicate() {
        var w = SlideWatcher()
        for n in [1, 2] {
            XCTAssertTrue(showUntilCandidate(&w, slide(n)))
            XCTAssertTrue(w.decide(slide(n), text: slideText, tileNames: []))
        }
        XCTAssertFalse(showUntilCandidate(&w, slide(1)))
    }

    /// A gallery of faces: only names and buttons to read. Rejected, and not checked again.
    func testGalleryIsRejectedAndRemembered() {
        var w = SlideWatcher()
        XCTAssertTrue(showUntilCandidate(&w, slide(5)))
        XCTAssertFalse(w.decide(slide(5), text: ["Tomas Reed", "Flo Jones", "Stop Video", "Share Screen", "Mute"],
                                tileNames: ["Tomas Reed", "Flo Jones"]))
        _ = w.look(slide(6))  // someone moves
        XCTAssertFalse(showUntilCandidate(&w, slide(5)), "the same view again is not re-read")
    }

    /// A picture-only slide still counts when the app says someone is sharing.
    func testSharingCueSavesAPictureSlide() {
        var w = SlideWatcher()
        XCTAssertTrue(showUntilCandidate(&w, slide(3)))
        XCTAssertTrue(w.decide(slide(3), text: ["Tomas Reed is presenting"], tileNames: ["Tomas Reed"]))
    }

    /// Webcam noise in a corner doesn't make a still slide look like it is moving.
    func testSmallNoiseStillCountsAsStill() {
        var w = SlideWatcher()
        XCTAssertFalse(w.look(slide(1, noise: 0)))
        XCTAssertFalse(w.look(slide(1, noise: 6)))
        XCTAssertTrue(w.look(slide(1, noise: 0)))
    }

    /// Slides from one template (same page, different lines) are different slides.
    func testTemplateSlidesDiffer() {
        XCTAssertGreaterThanOrEqual(slide(1).changedBlocks(slide(2)).filter { $0 }.count, SlideWatcher.newBlocks)
        XCTAssertEqual(slide(1).changedBlocks(slide(1)).filter { $0 }.count, 0)
    }

    /// Webcam tiles keep moving beside a shared slide: the slide is still saved, once.
    func testMovingWebcamStripBesideASlide() {
        func frame(_ n: Int, second: Int) -> Thumbnail {
            var f = PixelFrame(width: 320, height: 180, fill: (20, 20, 20))
            f.fill(PixelRect(x: 10, y: 10, width: 240, height: 160), (240, 240, 240))
            for i in 0..<(3 + n) { f.fill(PixelRect(x: 30, y: 30 + i * 30, width: 80 + i * 40, height: 12), (30, 30, 30)) }
            let shade = UInt8(60 + (second * 47) % 150)  // a face moving every second
            f.fill(PixelRect(x: 262, y: 10, width: 50, height: 40), (shade, shade / 2, shade))
            return Thumbnail(frame: f)
        }
        var w = SlideWatcher()
        var asked: [Int] = []
        for second in 0..<20 where w.look(frame(1, second: second)) {
            asked.append(second)
            XCTAssertTrue(w.decide(frame(1, second: second), text: slideText, tileNames: []))
        }
        XCTAssertEqual(asked.count, 1)
        for second in 20..<40 where w.look(frame(2, second: second)) { asked.append(second) }
        XCTAssertEqual(asked.count, 2, "the next slide, despite the webcam")
    }

    func testFileNameAndLog() throws {
        XCTAssertEqual(SlideLog.fileName(number: 3, at: 192.4), "003 00-03-12.jpg")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-slides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(SlideLog.load(from: folder), [])
        let slides = [SlideRecord(file: "001 00-00-05.jpg", at: 5, text: ["Hello"])]
        try SlideLog.save(slides, in: folder)
        XCTAssertEqual(SlideLog.load(from: folder), slides)
    }
}
