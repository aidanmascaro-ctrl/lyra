import Foundation

/// A rectangle in pixels, top-left origin.
public struct PixelRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }

    /// The same rectangle as fractions (0…1) of the frame, so it can be found again in a larger copy of it.
    public func normalised(in frame: PixelFrame) -> (x: Double, y: Double, width: Double, height: Double) {
        let w = Double(frame.width), h = Double(frame.height)
        return (Double(x) / w, Double(y) / h, Double(width) / w, Double(height) / h)
    }
}

/// One captured frame (or a small copy of it) as 8-bit RGBA, rows top to bottom. Kept in memory only.
public struct PixelFrame: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "rgba must hold width × height pixels")
        self.width = width; self.height = height; self.rgba = rgba
    }

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8)) {
        self.init(width: width, height: height, rgba: Array([fill.0, fill.1, fill.2, 255].repeated(width * height)))
    }

    public func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2])
    }

    /// Brightness 0…255 (Rec. 601 weights).
    public func luma(_ x: Int, _ y: Int) -> Double {
        let p = pixel(x, y)
        return 0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b)
    }

    // Drawing, for building test frames.
    public mutating func fill(_ rect: PixelRect, _ colour: (UInt8, UInt8, UInt8)) {
        for y in max(0, rect.y)..<min(height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(width, rect.x + rect.width) {
                let i = (y * width + x) * 4
                rgba[i] = colour.0; rgba[i + 1] = colour.1; rgba[i + 2] = colour.2; rgba[i + 3] = 255
            }
        }
    }

    public mutating func outline(_ rect: PixelRect, _ colour: (UInt8, UInt8, UInt8), thickness: Int) {
        let t = thickness
        fill(PixelRect(x: rect.x, y: rect.y, width: rect.width, height: t), colour)
        fill(PixelRect(x: rect.x, y: rect.y + rect.height - t, width: rect.width, height: t), colour)
        fill(PixelRect(x: rect.x, y: rect.y, width: t, height: rect.height), colour)
        fill(PixelRect(x: rect.x + rect.width - t, y: rect.y, width: t, height: rect.height), colour)
    }
}

private extension Array {
    func repeated(_ times: Int) -> [Element] {
        var out: [Element] = []
        out.reserveCapacity(count * times)
        for _ in 0..<times { out.append(contentsOf: self) }
        return out
    }
}
