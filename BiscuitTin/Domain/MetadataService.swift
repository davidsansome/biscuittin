import Foundation
import Photos
import AVFoundation
import ImageIO
import CoreLocation

/// Builds `AssetMetadata` for the info sheet (requirement 9).
///
/// EXIF is read through `PHContentEditingInput`'s file URL and `CGImageSource`, which parses
/// only the metadata headers — decoding a 48-megapixel image just to read its aperture would
/// violate §14 P3. Everything here is async and off the main thread; the sheet renders the
/// stub-derived subset first and swaps this in when it arrives.
final class MetadataService: @unchecked Sendable {
    private let resolver: PHAssetResolver
    private let geocoder = CLGeocoder()

    init(resolver: PHAssetResolver) {
        self.resolver = resolver
    }

    func metadata(for asset: Asset) async -> AssetMetadata {
        var metadata = AssetMetadata(stub: asset.stub)

        if let localIdentifier = asset.localIdentifier,
           let phAsset = resolver.resolve(localIdentifier) {
            await enrich(&metadata, from: phAsset)
        }
        // M5: fall back to the cached Immich `exif_json` for remote-only assets, and let
        // local values win per-field when both facets exist.

        if let coordinate = metadata.coordinate {
            metadata.placeName = await placeName(for: coordinate)
        }
        return metadata
    }

    // MARK: - PhotoKit

    private func enrich(_ metadata: inout AssetMetadata, from phAsset: PHAsset) async {
        metadata.captureDate = phAsset.creationDate ?? metadata.captureDate
        metadata.pixelSize = CGSize(width: phAsset.pixelWidth, height: phAsset.pixelHeight)
        if phAsset.mediaType == .video {
            metadata.durationSeconds = phAsset.duration
        }
        if let location = phAsset.location {
            metadata.coordinate = location.coordinate
        }

        let resources = PHAssetResource.assetResources(for: phAsset)
        let primary = resources.first { $0.type == .photo || $0.type == .video }
            ?? resources.first
        metadata.fileName = primary?.originalFilename
        if let primary, let size = primary.value(forKey: "fileSize") as? Int64 {
            metadata.fileSizeBytes = size
        }

        switch phAsset.mediaType {
        case .video:
            await enrichFromVideo(&metadata, phAsset: phAsset)
        default:
            await enrichFromImageProperties(&metadata, phAsset: phAsset)
        }
    }

    /// Reads EXIF/TIFF/GPS dictionaries without decoding pixel data.
    private func enrichFromImageProperties(_ metadata: inout AssetMetadata, phAsset: PHAsset) async {
        guard let url = await fullSizeImageURL(for: phAsset),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            metadata.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            metadata.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
            metadata.exposureSeconds = exif[kCGImagePropertyExifExposureTime] as? Double
            metadata.focalLengthMM = exif[kCGImagePropertyExifFocalLength] as? Double
            if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                metadata.iso = isoValues.first
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            metadata.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            metadata.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            metadata.pixelSize = CGSize(width: width, height: height)
        }
    }

    private func enrichFromVideo(_ metadata: inout AssetMetadata, phAsset: PHAsset) async {
        guard let avAsset = await avAsset(for: phAsset) else { return }

        if let duration = try? await avAsset.load(.duration) {
            metadata.durationSeconds = CMTimeGetSeconds(duration)
        }
        if let track = try? await avAsset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            metadata.pixelSize = size
        }
        if let common = try? await avAsset.load(.commonMetadata) {
            for item in common where item.commonKey == .commonKeyModel {
                metadata.cameraModel = try? await item.load(.stringValue)
            }
            for item in common where item.commonKey == .commonKeyMake {
                metadata.cameraMake = try? await item.load(.stringValue)
            }
        }
    }

    // MARK: - PhotoKit async bridges

    private func fullSizeImageURL(for phAsset: PHAsset) async -> URL? {
        await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            phAsset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.fullSizeImageURL)
            }
        }
    }

    private func avAsset(for phAsset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }
    }

    // MARK: - Reverse geocoding (no location permission required for EXIF coordinates)

    private func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        let parts = [placemark.locality ?? placemark.name,
                     placemark.administrativeArea,
                     placemark.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
