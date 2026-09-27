// Stamps each downloaded photo with the capture date, GPS position and iPhone camera details from
// photos.json, so the timeline, map, search and info sheet all have something real to show.
//
//   swift Tools/screenshots/tag_photos.swift
//
// Reads build/screenshots/raw, writes build/screenshots/tagged. The JPEG data is copied, not
// re-encoded; only the metadata changes.
import Foundation
import ImageIO

struct Photo: Decodable { let file, date, time: String; let lat, lon: Double }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let manifest = root.appendingPathComponent("Tools/screenshots/photos.json")
let rawDir = root.appendingPathComponent("build/screenshots/raw")
let outDir = root.appendingPathComponent("build/screenshots/tagged")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let photos = try JSONDecoder().decode([Photo].self, from: Data(contentsOf: manifest))
let parse = DateFormatter()
parse.dateFormat = "yyyy-MM-dd HH:mm"

for (i, p) in photos.enumerated() {
    guard let src = CGImageSourceCreateWithURL(rawDir.appendingPathComponent(p.file) as CFURL, nil) else {
        fatalError("missing \(p.file): run Tools/screenshots/fetch_photos.sh first")
    }
    let stamp = p.date.replacingOccurrences(of: "-", with: ":") + " " + p.time
        + ":" + String(format: "%02d", (i * 17) % 60)
    // Without an offset, `simctl addmedia` reads the time as UTC and the simulator shows it shifted
    // by the host's zone (a 22:10 photo appeared at 07:10). The simulator uses the host's zone, so
    // stamp that zone's offset *for the photo's date*, which also gets daylight saving right.
    let seconds = TimeZone.current.secondsFromGMT(for: parse.date(from: "\(p.date) \(p.time)")!)
    let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    let meta: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp,
            "OffsetTimeOriginal" as CFString: offset,
            "OffsetTimeDigitized" as CFString: offset,
            "OffsetTime" as CFString: offset,
            kCGImagePropertyExifLensModel: "iPhone 17 Pro back triple camera 6.765mm f/1.78",
            kCGImagePropertyExifFNumber: 1.78,
            kCGImagePropertyExifISOSpeedRatings: [[50, 64, 80, 125, 400][i % 5]],
            kCGImagePropertyExifExposureTime: [1.0 / 120, 1.0 / 250, 1.0 / 500, 1.0 / 60][i % 4],
            kCGImagePropertyExifFocalLength: 6.765,
            kCGImagePropertyExifFocalLenIn35mmFilm: 24,
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: stamp,
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone 17 Pro",
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: abs(p.lat),
            kCGImagePropertyGPSLatitudeRef: p.lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(p.lon),
            kCGImagePropertyGPSLongitudeRef: p.lon >= 0 ? "E" : "W",
        ],
    ]
    let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(p.file) as CFURL,
                                               CGImageSourceGetType(src)!, 1, nil)!
    CGImageDestinationAddImageFromSource(dest, src, 0, meta as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(p.file)") }
}
print("tagged \(photos.count) photos in \(outDir.path)")
