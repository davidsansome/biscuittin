import Foundation
import Photos
import AVFoundation

/// Supplies `AVPlayerItem`s for video pages in the viewer (DESIGN.md §10.1).
///
/// Local facets come from PhotoKit; remote-only assets stream from Immich's `/video/playback`
/// endpoint, with the credential in `AVURLAsset`'s HTTP headers so it rides along on every range
/// request AVFoundation makes. Item creation is always async so it never blocks a page swipe
/// (§14 P4).
final class VideoPlaybackProvider: @unchecked Sendable {
    enum PlaybackError: Error {
        case notAVideo
        case unavailableOffline
        case requestFailed
    }

    private let resolver: PHAssetResolver
    private let session: ImmichAuthSession

    /// Not among AVFoundation's published option keys, but the only way to give `AVURLAsset`
    /// request headers short of proxying every byte through a resource-loader delegate. Immich
    /// would also take the credential as a `sessionKey`/`apiKey` query parameter, which keeps
    /// to public API but writes the secret into every server and proxy access log; and the
    /// public cookies key covers session tokens only, not API keys.
    static let httpHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    init(resolver: PHAssetResolver, session: ImmichAuthSession) {
        self.resolver = resolver
        self.session = session
    }

    func playerItem(for asset: Asset) async throws -> AVPlayerItem {
        guard asset.stub.kind == .video else { throw PlaybackError.notAVideo }

        if let localIdentifier = asset.localIdentifier,
           let phAsset = resolver.resolve(localIdentifier) {
            return try await playerItem(for: phAsset)
        }
        guard let immichID = asset.immichID else { throw PlaybackError.requestFailed }
        return try await remotePlayerItem(immichID: immichID)
    }

    private func remotePlayerItem(immichID: String) async throws -> AVPlayerItem {
        guard let baseURL = session.baseURL, session.credential != nil else {
            throw PlaybackError.unavailableOffline
        }
        let session = session
        let client = ImmichClient(baseURL: baseURL, credentialProvider: { session.credential })
        let asset = AVURLAsset(url: await client.playbackURL(id: immichID),
                               options: [Self.httpHeaderFieldsKey: await client.playbackHeaders()])

        // Loaded here rather than left to the player, so an unreachable server or a rejected
        // credential becomes the page's error message instead of a spinner that never ends.
        do {
            guard try await asset.load(.isPlayable) else { throw PlaybackError.requestFailed }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlaybackError {
            throw error
        } catch {
            Log.device("ui", "Remote video \(immichID) failed to load: \(error)")
            throw PlaybackError.requestFailed
        }
        return AVPlayerItem(asset: asset)
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
