import Foundation

/// Finds the lit tile in a call window: Zoom, Meet, Teams and Discord all draw a coloured outline round whoever is
/// talking. No app's colour is hard-coded: a lit tile is any large, thin, hollow ring of one saturated hue. A green
/// shirt or a filled button is a block of colour, not a ring, and an underline is not closed, so neither counts.
public enum SpeakingTile {
    private static let minSaturation = 0.35  // Meet's light blue (#8AB4F8) is 0.44
    private static let minValue = 0.40
    /// Degrees of hue a ring's pixels may stray from where the ring was first touched (antialiasing, gradients).
    private static let hueTolerance: Float = 20
    /// A tile is at least this share of the window across and down; anything smaller is an icon.
    private static let minWidthShare = 0.06
    private static let minHeightShare = 0.06
    private static let minSidePixels = 14
    /// A ring is nearly empty inside: at most this share of its box is the ring's colour.
    private static let maxFill = 0.25
    /// At least this share of the ring's pixels lie in a thin band along its box's edges.
    private static let minEdgeShare = 0.9
    /// Each of the four sides is drawn along at least this share of its length (rounded corners lose a little).
    private static let minSideCover = 0.6

    /// Lit tiles, largest first. Usually one; empty when nobody's tile is lit (or the layout has no outline).
    public static func find(in frame: PixelFrame) -> [PixelRect] {
        let hues = accentHues(frame)
        var seen = [Bool](repeating: false, count: hues.count)
        var rings: [PixelRect] = []
        for start in hues.indices where hues[start] >= 0 && !seen[start] {
            let pixels = component(from: start, hues: hues, seen: &seen, width: frame.width)
            if let ring = ring(pixels, width: frame.width, frame: frame) { rings.append(ring) }
        }
        return rings.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// Each pixel's hue (0…360) when it is saturated and bright enough to be an outline's colour, else -1.
    private static func accentHues(_ frame: PixelFrame) -> [Float] {
        var hues = [Float](repeating: -1, count: frame.width * frame.height)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let p = frame.pixel(x, y)
                let r = Float(p.r) / 255, g = Float(p.g) / 255, b = Float(p.b) / 255
                let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
                guard Double(maxC) >= minValue, maxC > 0, Double(delta / maxC) >= minSaturation else { continue }
                var hue: Float
                if maxC == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
                else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
                else { hue = 60 * ((r - g) / delta + 4) }
                if hue < 0 { hue += 360 }
                hues[y * frame.width + x] = hue
            }
        }
        return hues
    }

    /// The 8-connected pixels of the start pixel's hue.
    private static func component(from start: Int, hues: [Float], seen: inout [Bool], width: Int) -> [Int] {
        let seed = hues[start]
        let height = hues.count / width
        var stack = [start], out: [Int] = []
        seen[start] = true
        while let i = stack.popLast() {
            out.append(i)
            let x = i % width, y = i / width
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let n = ny * width + nx
                    guard !seen[n], hues[n] >= 0 else { continue }
                    let gap = abs(hues[n] - seed)
                    guard min(gap, 360 - gap) <= hueTolerance else { continue }
                    seen[n] = true
                    stack.append(n)
                }
            }
        }
        return out
    }

    /// The component's box, if the component is a closed, thin, hollow outline the size of a tile.
    private static func ring(_ pixels: [Int], width: Int, frame: PixelFrame) -> PixelRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for i in pixels {
            let x = i % width, y = i / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        let w = maxX - minX + 1, h = maxY - minY + 1
        guard w >= max(minSidePixels, Int(Double(frame.width) * minWidthShare)),
              h >= max(minSidePixels, Int(Double(frame.height) * minHeightShare)),
              Double(pixels.count) / Double(w * h) <= maxFill else { return nil }
        let band = max(2, min(w, h) / 10)
        var top = Set<Int>(), bottom = Set<Int>(), left = Set<Int>(), right = Set<Int>()
        var onEdge = 0
        for i in pixels {
            let x = i % width, y = i / width
            var edge = false
            if y < minY + band { top.insert(x); edge = true }
            if y > maxY - band { bottom.insert(x); edge = true }
            if x < minX + band { left.insert(y); edge = true }
            if x > maxX - band { right.insert(y); edge = true }
            if edge { onEdge += 1 }
        }
        guard Double(onEdge) / Double(pixels.count) >= minEdgeShare else { return nil }
        let covered = [Double(top.count) / Double(w), Double(bottom.count) / Double(w),
                       Double(left.count) / Double(h), Double(right.count) / Double(h)]
        guard covered.allSatisfy({ $0 >= minSideCover }) else { return nil }
        return PixelRect(x: minX, y: minY, width: w, height: h)
    }
}
