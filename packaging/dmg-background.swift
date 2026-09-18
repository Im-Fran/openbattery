// Draws the disk image background: the landing page hero, at DMG window size.
// Values are taken verbatim from openbattery-landing (Hero.css, index.css):
// radial-gradient(90% 120% at 18% 0%, #1f2a38, #141d27 46%, #0a0f15),
// a 72px grid at rgba(238,242,246,.04) over a 360px one at .075.
//
// Regenerate the committed dmg-background.tiff with:
//   swiftc -O packaging/dmg-background.swift -o /tmp/bggen && /tmp/bggen packaging
//   tiffutil -cathidpicheck packaging/dmg-background.png \
//            packaging/dmg-background@2x.png -out packaging/dmg-background.tiff
// The two PNGs are throwaway inputs to tiffutil and are not committed.

import AppKit

let width = 640.0
let height = 400.0

func hex(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
}

func render(scale: Double, to path: String) {
    let w = Int(width * scale)
    let h = Int(height * scale)

    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("no context") }

    ctx.scaleBy(x: scale, y: scale)

    // Radial gradient. CSS places it at 18% across and 0% down, sized 90% of the
    // width by 120% of the height — an ellipse, so scale the CTM and draw a
    // unit circle into it.
    let stops: [CGFloat] = [0, 0.46, 1]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [hex(0x1f, 0x2a, 0x38), hex(0x14, 0x1d, 0x27), hex(0x0a, 0x0f, 0x15)] as CFArray,
        locations: stops
    )!

    ctx.saveGState()
    // CoreGraphics counts y from the bottom; CSS 0% down is the top edge.
    ctx.translateBy(x: width * 0.18, y: height)
    ctx.scaleBy(x: width * 0.9, y: height * 1.2)
    ctx.drawRadialGradient(
        gradient,
        startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: 1,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Grid lines, fine over coarse, 1px regardless of scale.
    func grid(cell: Double, alpha: Double) {
        ctx.setStrokeColor(CGColor(red: 238 / 255, green: 242 / 255, blue: 246 / 255, alpha: alpha))
        ctx.setLineWidth(1 / scale)
        var x = 0.0
        while x <= width {
            ctx.move(to: CGPoint(x: x + 0.5 / scale, y: 0))
            ctx.addLine(to: CGPoint(x: x + 0.5 / scale, y: height))
            x += cell
        }
        var y = height
        while y >= 0 {
            ctx.move(to: CGPoint(x: 0, y: y - 0.5 / scale))
            ctx.addLine(to: CGPoint(x: width, y: y - 0.5 / scale))
            y -= cell
        }
        ctx.strokePath()
    }

    grid(cell: 360, alpha: 0.075)
    grid(cell: 72, alpha: 0.04)

    guard let image = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(w)x\(h))")
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(scale: 1, to: "\(out)/dmg-background.png")
render(scale: 2, to: "\(out)/dmg-background@2x.png")
