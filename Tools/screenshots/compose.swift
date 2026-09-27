// Frames one raw simulator capture as an App Store screenshot: navy background in the app icon's
// palette, a two-line headline (second line in biscuit gold), a caption and the capture in a device
// bezel. Output is exactly App Store Connect's size: 1320x2868 (phone) or 2064x2752 (ipad).
//
//   swift Tools/screenshots/compose.swift <capture.png> <out.png> <phone|ipad> "<line 1>" "<line 2>" "<caption>"
//
// Usually run through compose_all.sh, which holds the captions.
import AppKit
import CoreGraphics

let a = CommandLine.arguments
let input = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let isPad = a[3] == "ipad"
let (W, H): (CGFloat, CGFloat) = isPad ? (2064, 2752) : (1320, 2868)
let line1 = a[4], line2 = a[5], sub = a[6]

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let navyTop = rgb(0x1E4A5E), navyBottom = rgb(0x0F2C3A)
let cream = rgb(0xF5EDE1), biscuit = rgb(0xE6B97E)

let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downward, like a layout.
ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

let bg = CGGradient(colorsSpace: nil, colors: [navyTop, navyBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: H), options: [])

// Soft biscuit glow behind the device.
let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xE6B97E, 0.28), rgb(0xE6B97E, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H * 0.62), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H * 0.62), endRadius: W * 0.75, options: [])

// Scalloped biscuit motif, faint, top-right and bottom-left.
func biscuitShape(center c: CGPoint, radius r: CGFloat, alpha: CGFloat) {
    ctx.setFillColor(rgb(0xE6B97E, alpha))
    let lobes = 14, lobeR = r * 0.24
    for i in 0..<lobes {
        let t = CGFloat(i) / CGFloat(lobes) * 2 * .pi
        ctx.fillEllipse(in: CGRect(x: c.x + cos(t) * (r - lobeR) - lobeR, y: c.y + sin(t) * (r - lobeR) - lobeR, width: lobeR * 2, height: lobeR * 2))
    }
    ctx.fillEllipse(in: CGRect(x: c.x - (r - lobeR), y: c.y - (r - lobeR), width: (r - lobeR) * 2, height: (r - lobeR) * 2))
}
biscuitShape(center: CGPoint(x: W * 0.96, y: H * 0.05), radius: W * 0.22, alpha: 0.07)
biscuitShape(center: CGPoint(x: W * 0.02, y: H * 0.93), radius: W * 0.26, alpha: 0.06)

// Text.
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: size)!
}
func draw(_ text: String, font f: NSFont, color: CGColor, top: CGFloat, kern: CGFloat = 0) -> CGFloat {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let s = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor(cgColor: color)!,
                                                          .paragraphStyle: para, .kern: kern])
    let width = W * 0.86
    let size = s.boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin]).size
    let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
    s.draw(with: CGRect(x: (W - width) / 2, y: top, width: width, height: ceil(size.height)), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
    return top + ceil(size.height)
}
let unit = isPad ? W / 1320 * 0.8 : 1
var y = (isPad ? 150 : 170) * unit
y = draw(line1, font: font(112 * unit, .heavy), color: cream, top: y, kern: -1)
y = draw(line2, font: font(112 * unit, .heavy), color: biscuit, top: y - 12 * unit, kern: -1)
y = draw(sub, font: font(48 * unit, .medium), color: rgb(0xF5EDE1, 0.72), top: y + 28 * unit)

// Device.
let bezel: CGFloat = isPad ? 26 : 24
// Fixed, so the device sits at the same height whether the caption takes one line or two.
let shotTop = max(y + (isPad ? 70 : 60) * unit, isPad ? 790 : 640)
let aspect = CGFloat(input.height) / CGFloat(input.width)
let shotW = min(W * 0.76, (H - shotTop - bezel - (isPad ? 110 : 100)) / aspect)
let shotH = shotW * aspect
let shotRect = CGRect(x: (W - shotW) / 2, y: shotTop, width: shotW, height: shotH)
let corner: CGFloat = isPad ? 44 : shotW * 0.125
let body = shotRect.insetBy(dx: -bezel, dy: -bezel)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 40), blur: 90, color: rgb(0x000000, 0.55))
ctx.addPath(CGPath(roundedRect: body, cornerWidth: corner + bezel, cornerHeight: corner + bezel, transform: nil))
ctx.setFillColor(rgb(0x0B0B0C)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: corner + bezel - 2, cornerHeight: corner + bezel - 2, transform: nil))
ctx.setStrokeColor(rgb(0x5A5E63)); ctx.setLineWidth(4); ctx.strokePath()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: shotRect, cornerWidth: corner, cornerHeight: corner, transform: nil)); ctx.clip()
// Undo the flip for the image so it is upright.
ctx.translateBy(x: 0, y: shotRect.maxY + shotRect.minY); ctx.scaleBy(x: 1, y: -1)
ctx.interpolationQuality = .high
ctx.draw(input, in: shotRect)
ctx.restoreGState()

let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
