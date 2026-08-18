import Foundation
import CoreGraphics
import ImageIO

// Renders a coarse ASCII map of a region so the actual framebuffer contents can be
// inspected without relying on visual interpretation of a downscaled screenshot.

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let yStart = Int(CommandLine.arguments[2]) ?? 0
let yEnd = Int(CommandLine.arguments[3]) ?? 200

guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("could not load"); exit(1)
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let ctx = CGContext(data: &pixels, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

let cols = 60
let rowStep = 8
let colWidth = width / cols
let scale = 3.0   // native px per point

print("region rows \(yStart)-\(yEnd) (pt \(Double(yStart)/scale)-\(Double(yEnd)/scale)), \(cols) cols")
print("col x-pt: 0" + String(repeating: " ", count: 20) + "~134" + String(repeating: " ", count: 18) + "~268   ~402")

var y = yStart
while y < min(yEnd, height) {
    var line = ""
    for c in 0..<cols {
        var maxLuma = 0
        for dy in 0..<rowStep {
            let yy = y + dy
            guard yy < height else { break }
            for x in (c * colWidth)..<min((c + 1) * colWidth, width) {
                let i = (yy * width + x) * 4
                let luma = (Int(pixels[i]) * 299 + Int(pixels[i+1]) * 587 + Int(pixels[i+2]) * 114) / 1000
                maxLuma = max(maxLuma, luma)
            }
        }
        line += maxLuma > 200 ? "#" : (maxLuma > 90 ? "+" : (maxLuma > 30 ? "." : " "))
    }
    print(String(format: "y=%4d pt=%5.1f |%@|", y, Double(y) / scale, line))
    y += rowStep
}
