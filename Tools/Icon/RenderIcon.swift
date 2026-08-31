// Renders the "Biscuit" app icon (concept 05) to a 1024x1024 PNG.
// Geometry mirrors icons-biscuit-tin/05-biscuit.svg, except the background is a
// full square: iOS applies the corner mask itself.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let center = 512.0

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0)
}

let tin = color(0x12303F)
let biscuit = color(0xD9A566)
let docker = color(0xA8763A)
let mount = color(0xF3EADA)
let sky = color(0x8FB6C8)
let sun = color(0xF0D08A)
let hills = color(0x3E6B57)

guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not create bitmap context")
}

// Match SVG's y-down coordinate system so the geometry below reads the same.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func disc(_ cx: Double, _ cy: Double, _ r: Double, _ fill: CGColor) {
    ctx.setFillColor(fill)
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}

// Background: full bleed, square corners.
ctx.setFillColor(tin)
ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))

// Scalloped biscuit edge: 16 bumps around the rim, then the body over them.
for i in 0..<16 {
    let a = Double(i) * .pi / 8
    disc(center + 286 * cos(a), center + 286 * sin(a), 58, biscuit)
}
disc(center, center, 286, biscuit)

// Docker holes, offset half a step so they sit between the scallops.
for i in 0..<8 {
    let a = .pi / 8 + Double(i) * .pi / 4
    disc(center + 236 * cos(a), center + 236 * sin(a), 15, docker)
}

// Photo mount, then the photograph clipped into a circle.
disc(center, center, 186, mount)

ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center - 152, y: center - 152, width: 304, height: 304))
ctx.clip()

ctx.setFillColor(sky)
ctx.fill(CGRect(x: 360, y: 360, width: 304, height: 304))
disc(570, 454, 38, sun)

ctx.setFillColor(hills)
ctx.beginPath()
ctx.move(to: CGPoint(x: 360, y: 664))
for p in [(436.0, 560.0), (494.0, 620.0), (544.0, 570.0), (664.0, 664.0)] {
    ctx.addLine(to: CGPoint(x: p.0, y: p.1))
}
ctx.closePath()
ctx.fillPath()

ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("could not render image") }

let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not create \(out.path)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write PNG") }
print("wrote \(out.path)")
