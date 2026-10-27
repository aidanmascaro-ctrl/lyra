import Foundation

/// A small grey copy of a frame (160×90), for telling cheaply whether parts of the picture moved or changed.
public struct Thumbnail: Equatable, Sendable {
    public static let width = 160
    public static let height = 90
    /// Comparisons are per block of a 20×10 grid, so a moving webcam tile can be told from a new slide.
    static let gridWidth = 20
    static let gridHeight = 10
    /// A pixel this much brighter or darker has changed; a block with this share of changed pixels has changed.
    private static let pixelChange = 24
    private static let blockShare = 0.1
    public let luma: [UInt8]

    /// Each thumbnail pixel is the average brightness of its patch of the frame.
    public init(frame: PixelFrame) {
        var out = [UInt8](repeating: 0, count: Self.width * Self.height)
        for ty in 0..<Self.height {
            let y0 = ty * frame.height / Self.height, y1 = max(y0 + 1, (ty + 1) * frame.height / Self.height)
            for tx in 0..<Self.width {
                let x0 = tx * frame.width / Self.width, x1 = max(x0 + 1, (tx + 1) * frame.width / Self.width)
                var sum = 0.0
                for y in y0..<min(y1, frame.height) { for x in x0..<min(x1, frame.width) { sum += frame.luma(x, y) } }
                out[ty * Self.width + tx] = UInt8(min(255, sum / Double((y1 - y0) * (x1 - x0))))
            }
        }
        luma = out
    }

    /// Which blocks of the grid differ from `other`, row by row.
    public func changedBlocks(_ other: Thumbnail) -> [Bool] {
        let bw = Self.width / Self.gridWidth, bh = Self.height / Self.gridHeight
        var out = [Bool](repeating: false, count: Self.gridWidth * Self.gridHeight)
        for gy in 0..<Self.gridHeight {
            for gx in 0..<Self.gridWidth {
                var changed = 0
                for y in (gy * bh)..<((gy + 1) * bh) {
                    for x in (gx * bw)..<((gx + 1) * bw) where abs(Int(luma[y * Self.width + x]) - Int(other.luma[y * Self.width + x])) > Self.pixelChange {
                        changed += 1
                    }
                }
                out[gy * Self.gridWidth + gx] = Double(changed) >= Self.blockShare * Double(bw * bh)
            }
        }
        return out
    }
}

/// Decides, a frame a second, when the call window shows a new slide worth saving. A frame is checked once it has
/// stayed still for 2 s (no transitions) and differs from every slide saved; it is saved if its text reads like a
/// slide, or the app says someone is sharing. Blocks that keep moving (webcam tiles beside a shared screen) are left
/// out of every comparison. Faces, a slide flipped back to, and views already turned down are skipped.
public struct SlideWatcher: Sendable {
    /// Seconds a picture must stay put before it is checked.
    static let stillFor = 2
    /// A block that changed in this many of the last `liveWindow` seconds is live video, not the slide.
    static let liveWindow = 8
    static let liveChanges = 4
    /// At least this many (non-video) blocks must differ from a saved slide or a turned-down view to be new.
    static let newBlocks = 3
    /// Words in lines of three or more words, other than tile names, that make a page of text a slide.
    static let minWords = 8
    private static let remembered = 8
    private static let sharingCues = ["is presenting", "are presenting", "is sharing", "are sharing", "'s screen", "’s screen", "viewing"]

    private var previous: Thumbnail?
    private var history: [[Bool]] = []
    private var stillCount = 0
    private var saved: [Thumbnail] = []
    private var turnedDown: [Thumbnail] = []

    public init() {}

    /// Takes this second's thumbnail. True when it should be read (OCR) and passed to `decide`.
    public mutating func look(_ thumb: Thumbnail) -> Bool {
        defer { previous = thumb }
        guard let previous else { return false }
        let changed = thumb.changedBlocks(previous)
        history = Array((history + [changed]).suffix(Self.liveWindow))
        let live = liveBlocks()
        let still = !zip(changed, live).contains { $0 && !$1 }
        stillCount = still ? stillCount + 1 : 0
        guard stillCount == Self.stillFor else { return false }
        return !(saved + turnedDown).contains { differing(thumb, $0, live: live) < Self.newBlocks }
    }

    /// True (and remembered as saved) when the checked frame's text makes it a slide; false remembers it as turned down.
    public mutating func decide(_ thumb: Thumbnail, text: [String], tileNames: Set<String>) -> Bool {
        let lower = text.joined(separator: "\n").lowercased()
        let cue = Self.sharingCues.contains { lower.contains($0) }
        let words = text.filter { !tileNames.contains($0) && TileName.clean($0) == nil }
            .map { $0.split(whereSeparator: \.isWhitespace).count }
            .filter { $0 >= 3 }
            .reduce(0, +)
        guard cue || words >= Self.minWords else {
            turnedDown = Array((turnedDown + [thumb]).suffix(Self.remembered))
            return false
        }
        saved.append(thumb)
        return true
    }

    private func liveBlocks() -> [Bool] {
        let count = Thumbnail.gridWidth * Thumbnail.gridHeight
        return (0..<count).map { i in history.filter { $0[i] }.count >= Self.liveChanges }
    }

    private func differing(_ a: Thumbnail, _ b: Thumbnail, live: [Bool]) -> Int {
        zip(a.changedBlocks(b), live).filter { $0 && !$1 }.count
    }
}

/// One saved slide: its file in `slides/`, when it was shown (seconds on the recording's timeline), and its text.
public struct SlideRecord: Codable, Equatable, Sendable {
    public let file: String
    public let at: Double
    public let text: [String]
    public init(file: String, at: Double, text: [String]) { self.file = file; self.at = at; self.text = text }
}

/// `slides.json` and the `slides/` folder at the top of the meeting's recordings folder.
public enum SlideLog {
    public static let fileName = "slides.json"
    public static let folderName = "slides"

    /// "003 00-03-12.jpg": the slide's number, then when it was shown.
    public static func fileName(number: Int, at seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%03d %02d-%02d-%02d.jpg", number, s / 3600, (s / 60) % 60, s % 60)
    }

    public static func load(from folder: URL) -> [SlideRecord] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([SlideRecord].self, from: data)) ?? []
    }

    public static func save(_ slides: [SlideRecord], in folder: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(slides).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }
}
