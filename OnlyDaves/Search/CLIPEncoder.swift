import Foundation
import CoreML
import CoreImage
import UIKit

/// Wraps the two MobileCLIP CoreML encoders (DESIGN.md D22, §19.4).
///
/// The encoders are held separately and loaded lazily because their lifetimes differ sharply
/// (P8): the **image** encoder is resident only while an indexing batch runs, while the **text**
/// encoder lives as long as the search UI is open. Together they are ~108 MB of weights, so
/// keeping either resident longer than needed is a real cost on an older device.
///
/// Every method is `nonisolated` and safe to call from a background task; `MLModel` is
/// thread-safe for prediction, and the loads are serialised by a lock.
final class CLIPEncoder: @unchecked Sendable {

    enum EncoderError: Error, LocalizedError {
        case modelMissing(String)
        case badOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing(let name):
                return "The search model \(name) is missing — run Tools/fetch_models.sh and rebuild."
            case .badOutput:
                return "The search model returned an unexpected output."
            }
        }
    }

    /// Measured from the compiled models (§19.4) — not assumed from the docs.
    private enum Contract {
        static let imageInput = "image"
        static let textInput = "text"
        /// Both encoders name their embedding output identically.
        static let output = "final_emb_1"
        static let imageSide = 256
    }

    private let bundle: Bundle
    private let lock = NSLock()
    private var imageModel: MLModel?
    private var textModel: MLModel?

    /// Reused across every image encode: creating a `CIContext` per call is expensive and it is
    /// internally thread-safe.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// True when the model resources are present. Search is disabled — not broken — without
    /// them, since `Tools/fetch_models.sh` is a manual build step.
    var isAvailable: Bool {
        bundle.url(forResource: "mobileclip_s0_image", withExtension: "mlmodelc") != nil
            && bundle.url(forResource: "mobileclip_s0_text", withExtension: "mlmodelc") != nil
    }

    // MARK: - Model lifetime

    private func model(named name: String, cached: inout MLModel?) throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw EncoderError.modelMissing(name)
        }
        let configuration = MLModelConfiguration()
        // Let CoreML pick: the Neural Engine handles these encoders well, but the simulator has
        // none and would otherwise fail rather than fall back.
        configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        cached = loaded
        Log.search.info("Loaded \(name, privacy: .public)")
        return loaded
    }

    private func imageEncoder() throws -> MLModel {
        try model(named: "mobileclip_s0_image", cached: &imageModel)
    }

    private func textEncoder() throws -> MLModel {
        try model(named: "mobileclip_s0_text", cached: &textModel)
    }

    /// Releases the image encoder's weights. Called when an indexing batch finishes (P8).
    func releaseImageEncoder() {
        lock.lock(); defer { lock.unlock() }
        imageModel = nil
    }

    /// Releases the text encoder's weights. Called when the search UI closes (P8).
    func releaseTextEncoder() {
        lock.lock(); defer { lock.unlock() }
        textModel = nil
    }

    // MARK: - Encoding

    func encode(text tokens: [Int32]) throws -> [Float] {
        let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)],
                                     dataType: .int32)
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: tokens.count)
        for (index, token) in tokens.enumerated() { pointer[index] = token }

        let input = try MLDictionaryFeatureProvider(
            dictionary: [Contract.textInput: MLFeatureValue(multiArray: array)])
        return try vector(from: try textEncoder().prediction(from: input))
    }

    /// Encodes several images in one `MLBatchProvider` call. The models are fixed batch-1
    /// (§19.4), so this amortises per-call overhead rather than widening a tensor — still worth
    /// it, at roughly a third off versus predicting one at a time.
    func encode(images: [CGImage]) throws -> [[Float]] {
        guard !images.isEmpty else { return [] }
        let providers = try images.map { image -> MLDictionaryFeatureProvider in
            let buffer = try Self.pixelBuffer(from: image, context: ciContext)
            return try MLDictionaryFeatureProvider(
                dictionary: [Contract.imageInput: MLFeatureValue(pixelBuffer: buffer)])
        }
        let batch = MLArrayBatchProvider(array: providers)
        let results = try imageEncoder().predictions(fromBatch: batch)
        return try (0..<results.count).map { try vector(from: results.features(at: $0)) }
    }

    private func vector(from provider: MLFeatureProvider) throws -> [Float] {
        guard let array = provider.featureValue(for: Contract.output)?.multiArrayValue,
              array.count == EmbeddingStore.dimensions else {
            throw EncoderError.badOutput
        }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        return Array(UnsafeBufferPointer(start: pointer, count: array.count))
    }

    // MARK: - Preprocessing

    /// Renders any source image into the encoder's exact 256×256 BGRA input.
    ///
    /// Aspect-fill plus centre crop, matching how the grid thumbnails the same asset (D13) — so
    /// the vector describes the framing the user actually sees. Normalisation (mean/std) is baked
    /// into the exported model, which is why nothing is applied here; the zero-shot control in
    /// `Tools/clipprobe.swift` is what confirms that end to end.
    static func pixelBuffer(from image: CGImage, context: CIContext) throws -> CVPixelBuffer {
        let side = Contract.imageSide
        let source = CIImage(cgImage: image)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { throw EncoderError.badOutput }

        let scale = max(CGFloat(side) / extent.width, CGFloat(side) / extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: scaled.extent.midX - CGFloat(side) / 2,
                          y: scaled.extent.midY - CGFloat(side) / 2,
                          width: CGFloat(side), height: CGFloat(side))
        let cropped = scaled.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw EncoderError.badOutput }
        context.render(cropped, to: buffer)
        return buffer
    }
}
