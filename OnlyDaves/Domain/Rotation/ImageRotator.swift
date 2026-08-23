import Foundation
import Photos
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Rotates still images by 90° (DESIGN.md D10).
///
/// Rotates *pixels* rather than flipping the EXIF orientation flag, because **PhotoKit requires
/// it**: edited asset content "must incorporate (or 'bake in') the intended orientation… the
/// orientation metadata that you write must declare the 'up' orientation, and the image data
/// must appear right-side up when presented without orientation metadata." A rendition carrying
/// the rotation in its flag instead is rejected with `PHPhotosError.invalidResource` — measured,
/// for both HEIC and JPEG.
///
/// Note this is *not* an Immich limitation. Immich honours the flag perfectly well: an image
/// uploaded with orientation 6 comes back with swapped display dimensions and a correctly
/// rotated server-side thumbnail. An earlier version of this comment blamed Immich; that was
/// wrong. The cost of the re-encode is generational loss on repeated rotations of one photo.
///
/// The source's EXIF orientation is applied first and the output is written with orientation 1,
/// so rotations never compound incorrectly.
struct ImageRotator: AssetRotator {
    let supportedKind: MediaKind = .image

    func rotateLocal(input: PHContentEditingInput,
                     clockwise: Bool,
                     outputType: UTType) async throws -> URL {
        guard let url = input.fullSizeImageURL else { throw RotationError.missingImageSource }
        // Must be the type PhotoKit asked for, not the source's: iOS requests a JPEG rendition
        // for a HEIC original, and handing it HEIC bytes fails with invalidResource.
        return try rotate(fileURL: url, clockwise: clockwise, preferredUTI: outputType.identifier)
    }

    func rotateRemoteOriginal(fileURL: URL, clockwise: Bool) async throws -> URL {
        try rotate(fileURL: fileURL, clockwise: clockwise, preferredUTI: nil)
    }

    // MARK: - Implementation

    func rotate(fileURL: URL, clockwise: Bool, preferredUTI: String?) throws -> URL {
        // `.applyOrientationProperty` bakes any existing EXIF orientation into the pixel data,
        // so the transform below always operates on what the user actually sees.
        guard let source = CIImage(contentsOf: fileURL,
                                   options: [.applyOrientationProperty: true]) else {
            throw RotationError.missingImageSource
        }

        // CIImage works in a y-up coordinate space, so an on-screen *clockwise* turn is a
        // negative angle here. Verified visually: a band along the bottom edge must end up on
        // the left edge after a clockwise rotation.
        let angle: CGFloat = clockwise ? -.pi / 2 : .pi / 2
        let rotated = source.transformed(by: CGAffineTransform(rotationAngle: angle))
        // Rotation moves the extent off the origin; bring it back so the render region is valid.
        let normalized = rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                                  y: -rotated.extent.origin.y))

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(normalized, from: normalized.extent) else {
            throw RotationError.renderFailed
        }

        let type = outputType(preferredUTI: preferredUTI, sourceURL: fileURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotate-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "jpg")

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                                type.identifier as CFString,
                                                                1, nil) else {
            throw RotationError.renderFailed
        }

        var properties = sourceProperties(of: fileURL)
        // The rotation is now in the pixels, so the file must declare the identity orientation.
        properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        properties[kCGImagePropertyTIFFDictionary] = stripOrientation(
            properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RotationError.renderFailed }
        return outputURL
    }

    /// Resolves the container to encode into.
    ///
    /// `preferredUTI` wins when given — for a PhotoKit rendition that is the type
    /// `renderedContentURL` demands, which is not necessarily the source's. Only the remote
    /// path leaves it nil, where keeping the original container is right.
    private func outputType(preferredUTI: String?, sourceURL: URL) -> UTType {
        if let preferredUTI, let type = UTType(preferredUTI), type.isSubtype(of: .image) {
            return type
        }
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier) {
            return type
        }
        return .jpeg
    }

    /// Carries EXIF, GPS and camera metadata across the re-encode.
    private func sourceProperties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return properties
    }

    private func stripOrientation(_ tiff: [CFString: Any]?) -> [CFString: Any]? {
        guard var tiff else { return nil }
        tiff[kCGImagePropertyTIFFOrientation] = CGImagePropertyOrientation.up.rawValue
        return tiff
    }
}
