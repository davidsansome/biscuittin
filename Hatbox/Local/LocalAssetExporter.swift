import Foundation
import Photos
import CryptoKit

/// Exports a PhotoKit original to a temp file, computing its SHA-1 on the way (DESIGN.md §8).
///
/// Streams in chunks rather than loading the resource: originals are routinely multi-gigabyte
/// videos, and the checksum has to be computed for every asset before upload (D12).
final class LocalAssetExporter: @unchecked Sendable {

    struct Export {
        let fileURL: URL
        let sha1Hex: String
        let filename: String
        let createdAt: Date
        let modifiedAt: Date
        let byteCount: Int64
    }

    enum ExportError: LocalizedError {
        case noResource
        case unavailable

        var errorDescription: String? {
            switch self {
            case .noResource: return "This item has no original file."
            case .unavailable: return "The original couldn’t be downloaded."
            }
        }
    }

    /// Immich identifies assets by SHA-1 of the original bytes, so this must hash exactly what
    /// gets uploaded.
    func export(asset: PHAsset) async throws -> Export {
        guard let resource = Self.primaryResource(for: asset) else { throw ExportError.noResource }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)-\(resource.originalFilename)")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // fetch iCloud originals

        var hasher = Insecure.SHA1()
        var byteCount: Int64 = 0

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw ExportError.unavailable
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { chunk in
                        hasher.update(data: chunk)
                        byteCount += Int64(chunk.count)
                        try? handle.write(contentsOf: chunk)
                    },
                    completionHandler: { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        try? handle.close()

        let digest = hasher.finalize()
        return Export(fileURL: destination,
                      sha1Hex: digest.map { String(format: "%02x", $0) }.joined(),
                      filename: resource.originalFilename,
                      createdAt: asset.creationDate ?? Date(),
                      modifiedAt: asset.modificationDate ?? asset.creationDate ?? Date(),
                      byteCount: byteCount)
    }

    /// Computes only the checksum, without keeping the bytes. Used to dedupe against the
    /// server before deciding to upload anything (D12 step 3).
    func checksum(asset: PHAsset) async throws -> String {
        guard let resource = Self.primaryResource(for: asset) else { throw ExportError.noResource }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        var hasher = Insecure.SHA1()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { hasher.update(data: $0) },
                completionHandler: { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The resource that represents the asset itself — the edited version when one exists, so
    /// the server receives what the user sees.
    static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    static func estimatedByteCount(for asset: PHAsset) -> Int64 {
        guard let resource = primaryResource(for: asset),
              let size = resource.value(forKey: "fileSize") as? Int64 else { return 0 }
        return size
    }
}
