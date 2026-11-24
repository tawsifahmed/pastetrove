import AppKit

/// The PasteTrove mark: a block P with depth, on a 100×100 design grid (y points down).
/// Shared by the menu bar icon and `scripts/make-icon`, so both always match.
enum BrandMark {
    /// The bright front face of the P, with its counter cut out.
    static let front = path(
        [(32, 24), (58, 24), (68, 34), (68, 46), (58, 56), (44, 56), (44, 74), (32, 74)],
        hole: [(44, 34), (54, 34), (57, 37), (57, 43), (54, 46), (44, 46)]
    )
    /// The same P pushed down and right: the shaded depth behind the front.
    static let side = path(
        [(37, 29), (63, 29), (73, 39), (73, 51), (63, 61), (49, 61), (49, 79), (37, 79)],
        hole: [(49, 39), (59, 39), (62, 42), (62, 48), (59, 51), (49, 51)]
    )
    /// The slanted right side of the bowl, a half-lit facet.
    static let bevel = path([(58, 24), (68, 34), (68, 46), (58, 56)])

    /// Menu bar template image: solid front face, faint depth. macOS tints it for light and dark menu bars.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Crop the grid to the mark (x 30…76, y 22…81) so it fills the menu bar height.
            let scale = rect.height / 59
            context.translateBy(x: (rect.width - 46 * scale) / 2, y: 0)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -30, y: -22)
            fill(side, NSColor.black.withAlphaComponent(0.4), in: context)
            fill(front, .black, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func fill(_ path: CGPath, _ color: NSColor, in context: CGContext) {
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath(using: .evenOdd)
    }

    private static func path(_ points: [(CGFloat, CGFloat)], hole: [(CGFloat, CGFloat)] = []) -> CGPath {
        let path = CGMutablePath()
        for shape in [points, hole] where !shape.isEmpty {
            path.addLines(between: shape.map { CGPoint(x: $0.0, y: $0.1) })
            path.closeSubpath()
        }
        return path
    }
}
