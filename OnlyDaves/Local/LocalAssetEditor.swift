import Foundation
import Photos

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
            let renderedURL = try await rotator.rotateLocal(input: input, clockwise: clockwise)
            defer { try? FileManager.default.removeItem(at: renderedURL) }
            let data = try Data(contentsOf: renderedURL)
            try data.write(to: output.renderedContentURL, options: .atomic)
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
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
