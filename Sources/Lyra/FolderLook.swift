import AppKit
import LyraCore
import SwiftUI

/// The folder palette on screen: muted, readable on the dark warm grey and on a light page.
extension FolderColour {
    var nsColor: NSColor {
        let (dark, light) = Self.rgb[self] ?? ((0.62, 0.62, 0.62), (0.52, 0.52, 0.52))
        return Chrome.dynamic(dark: NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1),
                              light: NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1))
    }

    var color: Color { Color(nsColor: nsColor) }

    var label: String { rawValue.capitalized }

    private typealias RGB = (CGFloat, CGFloat, CGFloat)
    private static let rgb: [FolderColour: (dark: RGB, light: RGB)] = [
        .grey: ((0.62, 0.62, 0.62), (0.52, 0.52, 0.52)),
        .red: ((0.89, 0.43, 0.41), (0.79, 0.29, 0.27)),
        .orange: ((0.91, 0.59, 0.33), (0.82, 0.47, 0.19)),
        .yellow: ((0.88, 0.76, 0.37), (0.70, 0.56, 0.10)),
        .green: ((0.49, 0.74, 0.47), (0.29, 0.57, 0.29)),
        .teal: ((0.38, 0.72, 0.72), (0.17, 0.54, 0.55)),
        .blue: ((0.44, 0.63, 0.92), (0.24, 0.45, 0.80)),
        .purple: ((0.69, 0.54, 0.89), (0.51, 0.36, 0.76)),
    ]

    /// A filled circle for the Colour menu. Menus draw SF Symbols in one tint, so this is a plain image.
    var swatch: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A folder's coloured glyph; open (`folder.fill`) when something is about to land in it.
struct FolderGlyph: View {
    let colour: FolderColour
    var open = false
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: open ? "folder.fill" : "folder")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(colour.color)
    }
}

/// Colour ▸ with the eight swatches, the current one ticked.
struct FolderColourMenu: View {
    let current: FolderColour
    let choose: (FolderColour) -> Void

    var body: some View {
        Menu("Colour") {
            ForEach(FolderColour.allCases, id: \.self) { colour in
                Toggle(isOn: Binding(get: { colour == current }, set: { _ in choose(colour) })) {
                    Label { Text(colour.label) } icon: { Image(nsImage: colour.swatch) }
                }
            }
        }
    }
}
