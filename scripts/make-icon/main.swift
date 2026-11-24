import AppKit

// Draws the 1024 px app icon: the BrandMark P on a graphite macOS tile.
// Built together with Sources/PasteTrove/BrandMark.swift by scripts/make-icon.sh.

let pixels: CGFloat = 1024
let output = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
// Work on the 100×100 design grid with y pointing down, like BrandMark.
context.translateBy(x: 0, y: pixels)
context.scaleBy(x: pixels / 100, y: -pixels / 100)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon shape: a superellipse (n = 5), 82 % of the canvas.
let tile = CGMutablePath()
for degrees in stride(from: 0.0, through: 360.0, by: 1.0) {
    let t = degrees * .pi / 180
    let c = cos(t), s = sin(t)
    let point = CGPoint(x: 50 + 41 * copysign(pow(abs(c), 0.4), c), y: 50 + 41 * copysign(pow(abs(s), 0.4), s))
    degrees == 0 ? tile.move(to: point) : tile.addLine(to: point)
}
tile.closeSubpath()

let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Drop shadow under the tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
context.addPath(tile)
context.setFillColor(color(0x1A1A1D))
context.fillPath()
context.restoreGState()

// Graphite gradient with a soft light from the top.
context.saveGState()
context.addPath(tile)
context.clip()
let body = CGGradient(colorsSpace: space, colors: [color(0x2B2B2F), color(0x0F0F11)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(body, start: CGPoint(x: 50, y: 9), end: CGPoint(x: 50, y: 91), options: [])
let light = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)] as CFArray, locations: [0, 0.6])!
context.drawRadialGradient(light, startCenter: CGPoint(x: 50, y: 9), startRadius: 0,
                           endCenter: CGPoint(x: 50, y: 9), endRadius: 74, options: [])
context.restoreGState()

// Hairline edge.
context.addPath(tile)
context.setStrokeColor(color(0xFFFFFF, 0.1))
context.setLineWidth(0.6)
context.strokePath()

// The mark: shaded depth, bright front, half-lit bevel.
BrandMark.fill(BrandMark.side, NSColor(cgColor: color(0x4A4A50))!, in: context)
BrandMark.fill(BrandMark.front, NSColor(cgColor: color(0xF4F4F5))!, in: context)
BrandMark.fill(BrandMark.bevel, NSColor(cgColor: color(0xB9B9BE, 0.55))!, in: context)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

// Optional second argument: the same icon as SVG (vector, sharp at any size), for the README.
if CommandLine.arguments.count > 2 {
    func svg(_ path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { element in
            let p = element.pointee.points
            let xy = { (i: Int) in String(format: "%.2f %.2f", p[i].x, p[i].y) }
            switch element.pointee.type {
            case .moveToPoint: d += "M\(xy(0))"
            case .addLineToPoint: d += "L\(xy(0))"
            case .closeSubpath: d += "Z"
            default: break
            }
        }
        return d
    }
    let svgText = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024">
          <defs>
            <linearGradient id="body" x1="50" y1="9" x2="50" y2="91" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="#2B2B2F"/><stop offset="1" stop-color="#0F0F11"/>
            </linearGradient>
            <radialGradient id="light" cx="50" cy="9" r="74" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="#fff" stop-opacity=".14"/><stop offset=".6" stop-color="#fff" stop-opacity="0"/>
            </radialGradient>
            <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
              <feDropShadow dx="0" dy="1.2" stdDeviation="1.4" flood-color="#000" flood-opacity=".45"/>
            </filter>
          </defs>
          <path d="\(svg(tile))" fill="#1A1A1D" filter="url(#shadow)"/>
          <path d="\(svg(tile))" fill="url(#body)"/>
          <path d="\(svg(tile))" fill="url(#light)"/>
          <path d="\(svg(tile))" fill="none" stroke="#fff" stroke-opacity=".1" stroke-width=".6"/>
          <path d="\(svg(BrandMark.side))" fill="#4A4A50" fill-rule="evenodd"/>
          <path d="\(svg(BrandMark.front))" fill="#F4F4F5" fill-rule="evenodd"/>
          <path d="\(svg(BrandMark.bevel))" fill="#B9B9BE" fill-opacity=".55"/>
        </svg>

        """
    try! svgText.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
}
