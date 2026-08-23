import Foundation
import Photos
import UniformTypeIdentifiers

/// Applies edits to the device photo library (DESIGN.md §8).
///
/// Rotation is committed through PhotoKit's content-editing flow, which keeps the original
/// recoverable ("Revert" in Photos) and lets successive rotations stack.
final class LocalAssetEditor: @unchecked Sendable {
    static let adjustmentFormatIdentifier = "dev.onlydaves.rotate"
    static let adjustmentFormatVersion = "1"

    func applyRotation(asset: PHAsset, clockwise: Bool, rotator: any AssetRotator) async throws {
        let input = try await contentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: Self.adjustmentFormatIdentifier,
            formatVersion: Self.adjustmentFormatVersion,
            data: Data([clockwise ? 1 : 0]))

        if let livePhotoRotator = rotator as? LivePhotoRotator {
            // Live Photos are written through PhotoKit's own editing context, which keeps the
            // still and its paired video in step (D10).
            try await livePhotoRotator.applyLivePhotoRotation(input: input,
                                                              output: output,
                                                              clockwise: clockwise)
        } else {
            let (destination, renderedType) = renditionTarget(for: input, output: output)
            let producedURL = try await rotator.rotateLocal(input: input,
                                                            clockwise: clockwise,
                                                            outputType: renderedType)
            defer { try? FileManager.default.removeItem(at: producedURL) }
            let data = try Data(contentsOf: producedURL)
            try data.write(to: destination, options: .atomic)
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
        }
    }


    /// Chooses where and in what container to write the edited rendition.
    ///
    /// `renderedContentURL` is only the *default* format — for a HEIC original iOS defaults to
    /// JPEG, which would silently inflate every rotated photo. Since iOS 17 the output can be
    /// asked for a specific container via `renderedContentURL(for:)`, so the original's own
    /// format is preferred whenever `supportedRenderedContentTypes` allows it, and the default
    /// is used only as a fallback.
    private func renditionTarget(for input: PHContentEditingInput,
                                 output: PHContentEditingOutput) -> (url: URL, type: UTType) {
        let fallbackType = output.defaultRenderedContentType
            ?? UTType(filenameExtension: output.renderedContentURL.pathExtension.lowercased())
            ?? .jpeg

        guard let sourceType = input.uniformTypeIdentifier.flatMap(UTType.init),
              sourceType != fallbackType,
              output.supportedRenderedContentTypes.contains(sourceType) else {
            return (output.renderedContentURL, fallbackType)
        }

        do {
            return (try output.renderedContentURL(for: sourceType), sourceType)
        } catch {
            // The type is advertised as supported but refused; the default always works.
            Log.device("ui", "rendition \(sourceType.identifier) refused: \(error)")
            return (output.renderedContentURL, fallbackType)
        }
    }

    /// Requests an editing session.
    ///
    /// `canHandleAdjustmentData` deliberately returns false: PhotoKit then hands us the
    /// *currently rendered* image rather than the untouched original, so each rotation composes
    /// on the last one. Returning true would require re-deriving the full edit stack ourselves.
    private func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    let cancelled = (info[PHContentEditingInputCancelledKey] as? Bool) ?? false
                    continuation.resume(throwing: cancelled
                                        ? CancellationError() as Error
                                        : RotationError.assetUnavailable)
                }
            }
        }
    }

    /// Deletes assets in a single change request, so the system shows one confirmation for the
    /// whole batch rather than one per asset (D11).
    func delete(assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}
