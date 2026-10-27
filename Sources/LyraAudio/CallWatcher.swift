import CoreGraphics
import Foundation
import LyraCore

/// Reads the call window a frame at a time while a call records: whose tile is lit (kept as names and times in
/// `onscreen.json`, never pictures), and, only when Aidan switched slides on, new slides (saved under `slides/`).
public actor CallWatcher {
    /// Frames are shrunk to this width to look for the lit tile and for slide changes; names and slides are read
    /// from the full frame.
    static let analysisWidth = 960

    private let folder: URL
    private var samples: [OnScreenSample]
    private var slides: [SlideRecord]
    private var slideWatcher = SlideWatcher()
    /// Every name seen on a lit tile: a slide check doesn't count them as slide text.
    private var tileNames: Set<String> = []
    public private(set) var slidesOn = false
    /// The first slide that couldn't be saved; kept so the note can say so.
    public private(set) var slideError: String?

    public init(folder: URL) {
        self.folder = folder
        samples = OnScreenLog.load(from: folder)
        slides = SlideLog.load(from: folder)
    }

    public var slideCount: Int { slides.count }

    public func setSlides(_ on: Bool) { slidesOn = on }

    /// Reads one frame, taken `t` seconds into the recording. Returns the text of a slide it saved, else nil.
    @discardableResult
    public func look(at image: CGImage, t: Double) -> [String]? {
        guard let small = CallWindow.pixels(image, width: Self.analysisWidth) else { return nil }
        // Two lit tiles (two people talking at once) say nothing sure about either.
        let rings = SpeakingTile.find(in: small)
        if rings.count == 1, let name = TileName.pick(CallWindow.lines(in: image, region: rings[0].normalised(in: small), correct: false)) {
            samples.append(OnScreenSample(t: t, name: name))
            tileNames.insert(name)
        }
        guard slidesOn else { return nil }
        let thumb = Thumbnail(frame: small)
        guard slideWatcher.look(thumb) else { return nil }
        let text = CallWindow.lines(in: image).map(\.text)
        guard slideWatcher.decide(thumb, text: text, tileNames: tileNames) else { return nil }
        return save(image, at: t, text: text) ? text : nil
    }

    /// Writes `onscreen.json` and `slides.json`, so a crash keeps what was seen so far.
    public func flush() throws {
        try OnScreenLog.save(samples, in: folder)
        if !slides.isEmpty { try SlideLog.save(slides, in: folder) }
    }

    private func save(_ image: CGImage, at t: Double, text: [String]) -> Bool {
        let dir = folder.appendingPathComponent(SlideLog.folderName, isDirectory: true)
        let name = SlideLog.fileName(number: slides.count + 1, at: t)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try CallWindow.writeJPEG(image, to: dir.appendingPathComponent(name))
            slides.append(SlideRecord(file: name, at: t, text: text))
            return true
        } catch {
            if slideError == nil { slideError = "Lyra couldn't save a slide from this call. (\(error.localizedDescription))" }
            return false
        }
    }
}
