import Foundation
import Photos
import AVFoundation
import UniformTypeIdentifiers

/// Rotates videos losslessly (DESIGN.md D10, M9).
///
/// Rewrites the video track's `preferredTransform` and remuxes with passthrough — no re-encode.
/// A multi-gigabyte video therefore rotates in roughly file-copy time with no generational
/// quality loss, which is exactly why video rotation was designed as its own strategy rather
/// than reusing the image path.
struct VideoRotator: AssetRotator {
    let supportedKind: MediaKind = .video

    func rotateLocal(input: PHContentEditingInput,
                     clockwise: Bool,
                     outputType: UTType) async throws -> URL {
        guard let avAsset = input.audiovisualAsset else { throw RotationError.missingImageSource }
        return try await rotate(asset: avAsset, clockwise: clockwise, outputType: outputType)
    }

    func rotateRemoteOriginal(fileURL: URL, clockwise: Bool) async throws -> URL {
        let inferred = UTType(filenameExtension: fileURL.pathExtension.lowercased()) ?? .quickTimeMovie
        return try await rotate(asset: AVURLAsset(url: fileURL), clockwise: clockwise, outputType: inferred)
    }

    /// Composes a quarter turn onto `existing` and shifts the rotated bounding box of
    /// `naturalSize` back so its origin sits at `(0, 0)`.
    static func normalizedTransform(existing: CGAffineTransform,
                                    naturalSize: CGSize,
                                    clockwise: Bool) -> CGAffineTransform {
        let quarter = CGAffineTransform(rotationAngle: clockwise ? .pi / 2 : -.pi / 2)
        let combined = existing.concatenating(quarter)
        let rotatedRect = CGRect(origin: .zero, size: naturalSize).applying(combined)
        return combined.concatenating(
            CGAffineTransform(translationX: -rotatedRect.minX, y: -rotatedRect.minY)
        )
    }

    static func exportContainer(for outputType: UTType) -> (fileType: AVFileType, ext: String) {
        if outputType.conforms(to: .mpeg4Movie) {
            return (.mp4, "mp4")
        }
        return (.mov, "mov")
    }

    private func rotate(asset: AVAsset, clockwise: Bool, outputType: UTType) async throws -> URL {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { throw RotationError.missingImageSource }

        let existing = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let normalized = Self.normalizedTransform(existing: existing,
                                                  naturalSize: naturalSize,
                                                  clockwise: clockwise)

        // The transform lives on the composition's track, so build a composition that
        // references the original samples rather than re-encoding them.
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RotationError.renderFailed
        }
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try compositionTrack.insertTimeRange(range, of: videoTrack, at: .zero)
        compositionTrack.preferredTransform = normalized

        // Carry every audio track across unchanged, clamped to its own time range so tracks
        // shorter than the video are never dropped.
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        for audioTrack in audioTracks {
            guard let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let audioRange = (try? await audioTrack.load(.timeRange)) ?? range
            let clampedDuration = CMTimeMinimum(audioRange.duration, duration)
            guard clampedDuration > .zero else { continue }
            let insertRange = CMTimeRange(start: audioRange.start, duration: clampedDuration)
            try? compositionAudio.insertTimeRange(insertRange, of: audioTrack, at: .zero)
        }

        // Passthrough preset: streams are copied, only the container's transform changes, so a
        // multi-gigabyte video rotates in roughly file-copy time with no quality loss.
        guard let passthrough = AVAssetExportSession(asset: composition,
                                                     presetName: AVAssetExportPresetPassthrough) else {
            throw RotationError.renderFailed
        }

        if let metadata = try? await asset.load(.metadata), !metadata.isEmpty {
            passthrough.metadata = metadata
        }

        let requested = Self.exportContainer(for: outputType)
        let (fileType, ext): (AVFileType, String) = passthrough.supportedFileTypes.contains(requested.fileType)
            ? requested
            : (.mov, "mov")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotate-\(UUID().uuidString).\(ext)")

        do {
            try await passthrough.export(to: outputURL, as: fileType)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }
}

/// Rotates Live Photos (DESIGN.md D10, M9).
///
/// Uses `PHLivePhotoEditingContext` so PhotoKit keeps the still and its paired video consistent;
/// rotating them separately would desynchronise the pair.
struct LivePhotoRotator: AssetRotator {
    let supportedKind: MediaKind = .livePhoto

    func rotateLocal(input: PHContentEditingInput,
                     clockwise: Bool,
                     outputType: UTType) async throws -> URL {
        // A Live Photo edit is applied through PhotoKit's own context rather than by producing
        // a rendition file, so this strategy is driven by `LocalAssetEditor` instead.
        throw RotationError.unsupportedMediaKind(.livePhoto)
    }

    func rotateRemoteOriginal(fileURL: URL, clockwise: Bool) async throws -> URL {
        // The server holds the still; rotate it exactly as a photo.
        try ImageRotator().rotate(fileURL: fileURL, clockwise: clockwise, preferredUTI: nil)
    }

    /// Applies the rotation to both components of a Live Photo.
    func applyLivePhotoRotation(input: PHContentEditingInput,
                                output: PHContentEditingOutput,
                                clockwise: Bool) async throws {
        guard let context = PHLivePhotoEditingContext(livePhotoEditingInput: input) else {
            throw RotationError.missingImageSource
        }
        let angle: CGFloat = clockwise ? -.pi / 2 : .pi / 2

        context.frameProcessor = { frame, _ in
            let rotated = frame.image.transformed(by: CGAffineTransform(rotationAngle: angle))
            return rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                                                             y: -rotated.extent.origin.y))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.saveLivePhoto(to: output) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? RotationError.renderFailed) }
            }
        }
    }
}
