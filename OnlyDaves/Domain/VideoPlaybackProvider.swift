import Foundation
import Photos
import AVFoundation

/// Supplies `AVPlayerItem`s for video pages in the viewer (DESIGN.md §10.1).
///
/// Local facets come from PhotoKit; remote-only assets will stream from Immich's
/// `/video/playback` endpoint with the bearer token injected into `AVURLAsset`'s HTTP
/// headers (M5). Item creation is always async so it never blocks a page swipe (§14 P4).
final class VideoPlaybackProvider: @unchecked Sendable {
    enum PlaybackError: Error {
        case notAVideo
        case unavailableOffline
        case requestFailed
    }

    private let resolver: PHAssetResolver

    init(resolver: PHAssetResolver) {
        self.resolver = resolver
    }

    func playerItem(for asset: Asset) async throws -> AVPlayerItem {
        guard asset.stub.kind == .video else { throw PlaybackError.notAVideo }

        if let localIdentifier = asset.localIdentifier,
           let phAsset = resolver.resolve(localIdentifier) {
            return try await playerItem(for: phAsset)
        }
        // M5: build an AVURLAsset against /api/assets/{id}/video/playback with
        // AVURLAssetHTTPHeaderFieldsKey carrying the bearer token.
        throw PlaybackError.unavailableOffline
    }

    private func playerItem(for phAsset: PHAsset) async throws -> AVPlayerItem {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true   // allow iCloud originals
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: phAsset,
                                                       options: options) { item, info in
                if let item {
                    continuation.resume(returning: item)
                } else {
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    continuation.resume(throwing: cancelled
                                        ? CancellationError() as Error
                                        : PlaybackError.requestFailed)
                }
            }
        }
    }

    /// Configures the shared audio session for playback. Called lazily on first play so the
    /// app does not interrupt other audio just by launching.
    func activateAudioSessionForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.ui.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
