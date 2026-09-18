// Draws the disk image background: the landing page hero, in light.
//
// The grid and the gradient geometry come from openbattery-landing
// (Hero.css, index.css): radial-gradient(90% 120% at 18% 0%, ...) with a 72px
// grid over a 360px one. The palette is inverted because the Finder paints icon
// labels dark once a background image is set, and no .DS_Store key controls
// that colour — on a dark background the names are barely readable.
//
// The window opens at 800x500 (see dmg-settings.py) but the image is drawn well
// past that, so it still covers the window when someone resizes it. The
// gradient is laid out over the window box; the overspill just continues.
//
// A single 1x PNG, deliberately: pairing it with a @2x render means a TIFF, and
// an uncompressed TIFF this size costs tens of megabytes inside the image.
//
// Regenerate the committed dmg-background.png with:
//   swiftc -O packaging/dmg-background.swift -o /tmp/bggen && /tmp/bggen packaging

import AppKit

let windowWidth = 800.0
let windowHeight = 500.0
let width = 1600.0
let height = 1000.0

let outDir = CommandLine.arguments.dropFirst().first ?? "."

func hex(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
}

guard let ctx = CGContext(
    data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

// CSS places the gradient at 18% across and 0% down, sized 90% of the width by
// 120% of the height — an ellipse, so scale the CTM and draw a unit circle.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [hex(0xf7, 0xf9, 0xfb), hex(0xea, 0xef, 0xf4), hex(0xd9, 0xe1, 0xea)] as CFArray,
    locations: [0, 0.46, 1]
)!

ctx.saveGState()
// CoreGraphics counts y from the bottom; CSS 0% down is the top edge.
ctx.translateBy(x: windowWidth * 0.18, y: height)
ctx.scaleBy(x: windowWidth * 0.9, y: windowHeight * 1.2)
ctx.drawRadialGradient(
    gradient,
    startCenter: .zero, startRadius: 0,
    endCenter: .zero, endRadius: 1,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
ctx.restoreGState()

func grid(cell: Double, alpha: Double) {
    ctx.setStrokeColor(CGColor(red: 20 / 255, green: 29 / 255, blue: 39 / 255, alpha: alpha))
    ctx.setLineWidth(1)
    var x = 0.0
    while x <= width {
        ctx.move(to: CGPoint(x: x + 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: x + 0.5, y: height))
        x += cell
    }
    var y = height
    while y >= 0 {
        ctx.move(to: CGPoint(x: 0, y: y - 0.5))
        ctx.addLine(to: CGPoint(x: width, y: y - 0.5))
        y -= cell
    }
    ctx.strokePath()
}

grid(cell: 360, alpha: 0.12)
grid(cell: 72, alpha: 0.064)

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
let path = "\(outDir)/dmg-background.png"
try! png.write(to: URL(fileURLWithPath: path))
print("wrote \(path) (\(Int(width))x\(Int(height)))")
