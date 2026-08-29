import Foundation
import CoreML
import CoreImage
import Vision

// Zero-shot control experiment for the search pipeline (DESIGN.md §19).
//
// Encodes an image and a list of prompts, then prints their cosine similarities ranked. If the
// tokenizer, the image preprocessing, or the embedding comparison is wrong, the *correct* caption
// stops winning — which no unit test on any single stage would catch. Run it against images whose
// content you already know.
//
// Build (the copy to `main.swift` is required — Swift only allows top-level statements in a file
// with that name, and this tool needs a second file for the tokenizer):
//
//   mkdir -p /tmp/clipprobe-build && cp Tools/clipprobe.swift /tmp/clipprobe-build/main.swift
//   swiftc -O /tmp/clipprobe-build/main.swift OnlyDaves/Search/CLIPTokenizer.swift -o /tmp/clipprobe
//   /tmp/clipprobe <image.jpg> "a photo of a waterfall" "a photo of a dog" …
//
// Run it from the repository root; the model paths are relative to it.

let modelDir = URL(fileURLWithPath: "OnlyDaves/Resources/Models")

func compiled(_ name: String) throws -> MLModel {
    let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).mlmodelc")
    if !FileManager.default.fileExists(atPath: cache.path) {
        let url = try MLModel.compileModel(at: modelDir.appendingPathComponent("\(name).mlpackage"))
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.moveItem(at: url, to: cache)
    }
    return try MLModel(contentsOf: cache)
}

func normalized(_ v: [Float]) -> [Float] {
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return norm > 0 ? v.map { $0 / norm } : v
}

func vector(from provider: MLFeatureProvider) -> [Float] {
    guard let array = provider.featureValue(for: "final_emb_1")?.multiArrayValue else { return [] }
    return (0..<array.count).map { Float(truncating: array[$0]) }
}

// MARK: - Image side

/// Renders any source image into the encoder's exact 256×256 BGRA input. Aspect-fill + centre
/// crop matches how the grid thumbnails these assets, so the indexer sees what the user sees.
func pixelBuffer(from url: URL, side: Int = 256) throws -> CVPixelBuffer {
    guard let source = CIImage(contentsOf: url) else { fatalError("could not read \(url.path)") }
    let extent = source.extent
    let scale = max(CGFloat(side) / extent.width, CGFloat(side) / extent.height)
    let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let cropRect = CGRect(x: scaled.extent.midX - CGFloat(side) / 2,
                          y: scaled.extent.midY - CGFloat(side) / 2,
                          width: CGFloat(side), height: CGFloat(side))
    let cropped = scaled.cropped(to: cropRect)
        .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard let buffer else { fatalError("could not allocate pixel buffer") }
    CIContext().render(cropped, to: buffer)
    return buffer
}

// MARK: - Run

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: clipprobe <image> <prompt> [<prompt>…]")
    exit(1)
}
let imageURL = URL(fileURLWithPath: args[0])
let prompts = Array(args.dropFirst())

let imageModel = try compiled("mobileclip_s0_image")
let textModel = try compiled("mobileclip_s0_text")
let tokenizer = try CLIPTokenizer(vocabURL: modelDir.appendingPathComponent("clip_vocab.json"),
                                  mergesURL: modelDir.appendingPathComponent("clip_merges.txt"))

let buffer = try pixelBuffer(from: imageURL)
let imageOut = try imageModel.prediction(from: try MLDictionaryFeatureProvider(
    dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
let imageVector = normalized(vector(from: imageOut))

print("image: \(imageURL.lastPathComponent)  (embedding dim \(imageVector.count))")
print()

var scored = [(String, Float)]()
for prompt in prompts {
    let ids = tokenizer.encodePadded(prompt)
    let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)],
                                 dataType: .int32)
    for (i, id) in ids.enumerated() { array[i] = NSNumber(value: id) }
    let textOut = try textModel.prediction(from: try MLDictionaryFeatureProvider(
        dictionary: ["text": MLFeatureValue(multiArray: array)]))
    let textVector = normalized(vector(from: textOut))
    let similarity = zip(imageVector, textVector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    scored.append((prompt, similarity))
}

for (rank, entry) in scored.sorted(by: { $0.1 > $1.1 }).enumerated() {
    print(String(format: "%d. %.4f  %@", rank + 1, entry.1, entry.0))
}
