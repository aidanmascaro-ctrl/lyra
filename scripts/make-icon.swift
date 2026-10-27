import AppKit

// Draws Lyra's app icon, a warm white "waveform" on a dark warm-grey rounded square, at every size an .iconset
// needs. No image files go in: it is drawn here at build time.
// Usage: swift scripts/make-icon.swift <out.iconset>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// One square PNG, `pixels` wide, on Apple's icon grid (an 824/1024 tile, centred, with its corner radius).
func icon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let size = CGFloat(pixels), unit = size / 1024
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)
    NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.25, blue: 0.23, alpha: 1),
               ending: NSColor(srgbRed: 0.15, green: 0.14, blue: 0.13, alpha: 1))?.draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 430 * unit, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.96, green: 0.93, blue: 0.88, alpha: 1)]))
    guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    else { return nil }
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let png = icon(pixels: base * scale) else {
            FileHandle.standardError.write(Data("couldn't draw \(name)\n".utf8))
            exit(1)
        }
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
