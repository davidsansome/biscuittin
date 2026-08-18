import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let calendar = Calendar.current
let now = Date()

func exifDateString(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return f.string(from: date)
}

func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> CGColor {
    let c = (1 - abs(2 * l - 1)) * s
    let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
    let m = l - c / 2
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    switch Int(h * 6) % 6 {
    case 0: (r, g, b) = (c, x, 0)
    case 1: (r, g, b) = (x, c, 0)
    case 2: (r, g, b) = (0, c, x)
    case 3: (r, g, b) = (0, x, c)
    case 4: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                   components: [r + m, g + m, b + m, 1])!
}

// Distinct, easily-distinguished tiles.
func makeImage(index: Int, width: Int, height: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let hue = CGFloat(index % 24) / 24.0

    ctx.setFillColor(hsl(hue, 0.65, 0.55))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Contrasting band along one edge so rotation is visible later (M3/M9).
    ctx.setFillColor(hsl((hue + 0.5).truncatingRemainder(dividingBy: 1), 0.8, 0.32))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 5))

    // Crude big numeral so individual tiles are identifiable in screenshots.
    ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.92])!)
    let n = index % 10
    let blockW = width / 12
    for i in 0...n {
        ctx.fill(CGRect(x: width / 2 - (n * blockW) / 2 + i * blockW,
                        y: height / 2 - blockW / 2,
                        width: blockW - 4, height: blockW))
    }
    return ctx.makeImage()
}

func writeJPEG(_ image: CGImage, to url: URL, date: Date, index: Int) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    let stamp = exifDateString(date)
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp,
            kCGImagePropertyExifLensModel: "OnlyDaves Test Lens 24mm",
            kCGImagePropertyExifFNumber: 1.8,
            kCGImagePropertyExifISOSpeedRatings: [index % 6 == 0 ? 400 : 100],
            kCGImagePropertyExifExposureTime: 0.008,
            kCGImagePropertyExifFocalLength: 24
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: stamp,
            kCGImagePropertyTIFFMake: "OnlyDaves",
            kCGImagePropertyTIFFModel: "Test Camera \(index % 3 + 1)"
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 51.5074 + Double(index % 5) * 0.01,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.1278 + Double(index % 5) * 0.01,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

// (daysAgo, countOfPhotos) — shaped to exercise day / week / month grouping.
let plan: [(Int, Int)] = [
    (0, 7), (1, 5), (2, 3), (4, 6), (6, 4),
    (9, 5), (12, 3), (16, 7), (23, 4),
    (38, 6), (52, 3), (70, 5), (140, 4), (400, 3)
]

var index = 0
for (daysAgo, count) in plan {
    for slot in 0..<count {
        guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now),
              let date = calendar.date(bySettingHour: (8 + slot) % 22, minute: (slot * 13) % 60,
                                       second: 0, of: day) else { continue }
        let landscape = index % 3 != 0
        let w = landscape ? 1400 : 900
        let h = landscape ? 900 : 1400
        guard let image = makeImage(index: index, width: w, height: h) else { continue }
        let url = outDir.appendingPathComponent(String(format: "photo-%03d.jpg", index))
        writeJPEG(image, to: url, date: date, index: index)
        index += 1
    }
}
print("wrote \(index) photos")

// MARK: - Videos with varied durations, to exercise the duration badge.

func writeVideo(to url: URL, durationSeconds: Double, colorIndex: Int, creation: Date) {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 640,
        AVVideoHeightKey: 480
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 640,
        kCVPixelBufferHeightKey as String: 480
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                       sourcePixelBufferAttributes: attrs)
    let creationItem = AVMutableMetadataItem()
    creationItem.identifier = .quickTimeMetadataCreationDate
    creationItem.value = ISO8601DateFormatter().string(from: creation) as NSString
    writer.metadata = [creationItem]

    guard writer.canAdd(input) else { return }
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let fps: Int32 = 12
    let frames = max(2, Int(durationSeconds * Double(fps)))
    var pool: CVPixelBuffer?

    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        guard let bufferPool = adaptor.pixelBufferPool else { break }
        CVPixelBufferPoolCreatePixelBuffer(nil, bufferPool, &pool)
        guard let buffer = pool else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer),
           let ctx = CGContext(data: base, width: 640, height: 480, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            let progress = CGFloat(frame) / CGFloat(frames)
            ctx.setFillColor(hsl(CGFloat(colorIndex % 8) / 8.0, 0.7, 0.45))
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
            ctx.fill(CGRect(x: 0, y: 200, width: 640 * progress, height: 80))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }

    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
}

let videoPlan: [(Double, Int)] = [(4, 0), (23, 1), (75, 2)]
for (i, item) in videoPlan.enumerated() {
    let date = calendar.date(byAdding: .day, value: -item.1, to: now) ?? now
    let url = outDir.appendingPathComponent(String(format: "video-%02d.mov", i))
    writeVideo(to: url, durationSeconds: item.0, colorIndex: i, creation: date)
    print("wrote video \(url.lastPathComponent) (\(item.0)s)")
}
