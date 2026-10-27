import SwiftUI

/// Lays its views out left to right and wraps to a new line when the next one won't fit, so a row of pills never
/// runs off the edge. Each view keeps its natural size; one wider than the whole line is narrowed to it. Views on a
/// line share a vertical centre.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = Self.frames(for: sizes(subviews, width: width), width: width, spacing: spacing, lineSpacing: lineSpacing)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(for: sizes(subviews, width: bounds.width), width: bounds.width,
                                 spacing: spacing, lineSpacing: lineSpacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func sizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > width else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }

    /// Where each item goes in a line `width` wide, from the top left.
    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> [CGRect] {
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let w = min(size.width, width)
            if !lines[lines.count - 1].isEmpty, x + spacing + w > width {
                lines.append([]); x = 0
            }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + w
            lines[lines.count - 1].append(i)
        }
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for i in line {
                let w = min(sizes[i].width, width)
                frames[i] = CGRect(x: x, y: y + (height - sizes[i].height) / 2, width: w, height: sizes[i].height)
                x += w + spacing
            }
            y += height + lineSpacing
        }
        return frames
    }
}
