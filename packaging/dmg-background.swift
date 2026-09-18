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
//
// Flags: --light inverts the palette, --cards draws plates behind the labels.

import AppKit

let width = 800.0
let height = 500.0

// Icon centres, mirrored in packaging/dmg-settings.py.
let iconCentres = [200.0, 600.0]
let iconCentreY = 230.0
let iconSize = 128.0

let args = CommandLine.arguments
let outDir = args.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "."
let light = args.contains("--light")
let cards = args.contains("--cards")

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
    let colors = light
        ? [hex(0xf7, 0xf9, 0xfb), hex(0xea, 0xef, 0xf4), hex(0xd9, 0xe1, 0xea)]
        : [hex(0x1f, 0x2a, 0x38), hex(0x14, 0x1d, 0x27), hex(0x0a, 0x0f, 0x15)]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0, 0.46, 1]
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
        let line = light
            ? CGColor(red: 20 / 255, green: 29 / 255, blue: 39 / 255, alpha: alpha * 1.6)
            : CGColor(red: 238 / 255, green: 242 / 255, blue: 246 / 255, alpha: alpha)
        ctx.setStrokeColor(line)
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

    // The Finder draws icon labels dark once a background image is set, and no
    // .DS_Store key controls that colour. Plates keep the names readable when
    // the background behind them is dark.
    if cards {
        let cardWidth = 208.0
        let cardTop = iconCentreY - iconSize / 2 - 22
        let cardHeight = 200.0
        for centre in iconCentres {
            let rect = CGRect(
                x: centre - cardWidth / 2,
                y: height - cardTop - cardHeight,
                width: cardWidth,
                height: cardHeight
            )
            let card = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
            ctx.addPath(card)
            ctx.setFillColor(CGColor(red: 233 / 255, green: 238 / 255, blue: 243 / 255, alpha: 0.9))
            ctx.fillPath()
            ctx.addPath(card)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    guard let image = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(w)x\(h))")
}

render(scale: 1, to: "\(outDir)/dmg-background.png")
render(scale: 2, to: "\(outDir)/dmg-background@2x.png")
