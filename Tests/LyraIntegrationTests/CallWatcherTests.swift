import AppKit
import CoreGraphics
import LyraAudio
import LyraCore
import XCTest

/// Frames drawn like a call window: a 2×2 gallery with name labels, one tile lit; and a shared slide.
enum FakeCall {
    static let size = CGSize(width: 1600, height: 1000)
    static let names = ["Tomas Reed", "Flo Jones", "Aidan Mascaro", "Marco Diaz"]

    static func gallery(lit: Int?, ring: NSColor = NSColor(srgbRed: 0.14, green: 0.85, blue: 0.35, alpha: 1)) -> CGImage {
        draw { _ in
            for (i, name) in names.enumerated() {
                let tile = tileRect(i)
                NSColor(white: 0.24, alpha: 1).setFill()
                NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12).fill()
                NSColor(white: 0.45, alpha: 1).setFill()
                NSBezierPath(ovalIn: CGRect(x: tile.midX - 80, y: tile.midY - 60, width: 160, height: 160)).fill()  // a head
                text(name, at: CGPoint(x: tile.minX + 20, y: tile.minY + 18), size: 28, colour: .white)
                if i == lit {
                    ring.setStroke()
                    let path = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 12, yRadius: 12)
                    path.lineWidth = 6
                    path.stroke()
                }
            }
        }
    }

    static func slide(_ title: String) -> CGImage {
        draw { _ in
            NSColor.white.setFill()
            CGRect(x: 40, y: 40, width: 1520, height: 920).fill()
            text(title, at: CGPoint(x: 120, y: 780), size: 64, colour: .black)
            for (i, line) in ["Revenue grew twelve percent on last year", "Two new clients signed in Perth",
                              "Next step is the workshop series"].enumerated() {
                text("• " + line, at: CGPoint(x: 140, y: 620 - CGFloat(i) * 110), size: 44, colour: .darkGray)
            }
            text("Tomas Reed is presenting", at: CGPoint(x: 60, y: 60), size: 22, colour: .gray)
        }
    }

    /// Tiles in AppKit's bottom-left coordinates: index 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    private static func tileRect(_ i: Int) -> CGRect {
        CGRect(x: i % 2 == 0 ? 40 : 820, y: i < 2 ? 520 : 40, width: 740, height: 440)
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, colour: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: colour])
    }

    private static func draw(_ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}

final class CallWatcherTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-call-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Real Vision on drawn frames: the lit tile's name is kept, frames are not; nothing saved with slides off.
    func testReadsTheLitTilesName() async throws {
        let watcher = CallWatcher(folder: folder)
        for (t, lit) in [(1.0, 1), (2.0, 1), (3.0, 3), (4.0, nil)] as [(Double, Int?)] {
            await watcher.look(at: FakeCall.gallery(lit: lit), t: t, saveSlides: false)
        }
        await watcher.look(at: FakeCall.gallery(lit: 2, ring: NSColor(srgbRed: 0.54, green: 0.71, blue: 0.97, alpha: 1)), t: 5, saveSlides: false)  // Meet blue
        try await watcher.flush()
        XCTAssertEqual(OnScreenLog.load(from: folder), [OnScreenSample(t: 1, name: "Flo Jones"), OnScreenSample(t: 2, name: "Flo Jones"),
                                                        OnScreenSample(t: 3, name: "Marco Diaz"), OnScreenSample(t: 5, name: "Aidan Mascaro")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("slides").path), "slides were off")
    }

    func testSavesEachSlideOnceWhenSwitchedOn() async throws {
        let watcher = CallWatcher(folder: folder)
        var saved: [[String]] = []
        let frames = Array(repeating: FakeCall.gallery(lit: 0), count: 4) + Array(repeating: FakeCall.slide("Q3 Pricing"), count: 4)
            + Array(repeating: FakeCall.slide("Workshop plan"), count: 4) + Array(repeating: FakeCall.slide("Q3 Pricing"), count: 4)
        for (t, frame) in frames.enumerated() {
            if let text = await watcher.look(at: frame, t: Double(t), saveSlides: true) { saved.append(text) }
        }
        try await watcher.flush()
        XCTAssertEqual(saved.count, 2, "the gallery isn't a slide, and flipping back isn't new")
        let log = SlideLog.load(from: folder)
        XCTAssertEqual(log.map(\.file), ["001 00-00-06.jpg", "002 00-00-10.jpg"])
        XCTAssertTrue(log[0].text.contains("Q3 Pricing"), "\(log[0].text)")
        for slide in log {
            XCTAssertNotNil(NSImage(contentsOf: folder.appendingPathComponent("slides").appendingPathComponent(slide.file)))
        }
    }
}

/// Real ScreenCaptureKit: shows a drawn call in a window of the test's own, captures it the way recording does, and
/// reads the lit tile. Skips without Screen Recording permission; never prompts for it.
final class CallWindowCaptureTests: XCTestCase {
    @MainActor
    func testCapturesItsOwnCallWindow() async throws {
        try requireIntegration()
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Screen Recording permission not granted")
        _ = NSApplication.shared
        let image = FakeCall.gallery(lit: 3)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Lyra fake call"
        let view = NSImageView(image: NSImage(cgImage: image, size: CGSize(width: 800, height: 500)))
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))

        let captured = await CallWindow.frame(pid: getpid(), startTitle: "Lyra fake call")
        let frame = try XCTUnwrap(captured, "the test's own window wasn't captured")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = CallWatcher(folder: folder)
        await watcher.look(at: frame, t: 1, saveSlides: false)
        try await watcher.flush()
        XCTAssertEqual(OnScreenLog.load(from: folder).map(\.name), ["Marco Diaz"])
    }
}
