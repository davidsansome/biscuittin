import UIKit

/// Fetches and caches remote renditions for `ImageLoader` (DESIGN.md D13, §10.1).
///
/// Kept behind a protocol so `ImageLoader` has no dependency on the Immich stack and stays
/// usable — and testable — with no server configured.
protocol RemoteImageFetching: AnyObject, Sendable {
    /// Returns a cached image synchronously when one is available, so grid cells can be filled
    /// without any async hop while scrolling (§14 P4).
    func cachedImage(immichID: String, variant: ImageVariant) -> UIImage?
    func image(immichID: String, variant: ImageVariant) async throws -> UIImage
}

final class RemoteImageFetcher: RemoteImageFetching, @unchecked Sendable {
    private let session: ImmichAuthSession
    private let cache: RemoteThumbnailCache
    private let clientFactory: @Sendable (URL) -> ImmichClient
    private let onCredentialRejected: @Sendable () -> Void

    private let lock = NSLock()
    private var credentialCheck: Task<Void, Never>?

    init(session: ImmichAuthSession,
         cache: RemoteThumbnailCache,
         clientFactory: (@Sendable (URL) -> ImmichClient)? = nil,
         onCredentialRejected: (@Sendable () -> Void)? = nil) {
        self.session = session
        self.cache = cache
        self.clientFactory = clientFactory ?? { url in
            ImmichClient(baseURL: url, credentialProvider: { session.credential })
        }
        self.onCredentialRejected = onCredentialRejected ?? { session.markExpired() }
    }

    func cachedImage(immichID: String, variant: ImageVariant) -> UIImage? {
        cache.image(for: RemoteThumbnailCache.key(immichID: immichID,
                                                  variant: Self.variantKey(variant)))
    }

    func image(immichID: String, variant: ImageVariant) async throws -> UIImage {
        let key = RemoteThumbnailCache.key(immichID: immichID, variant: Self.variantKey(variant))
        if let cached = cache.image(for: key) { return cached }

        guard let baseURL = session.baseURL, session.credential != nil else {
            throw ImmichError.notConfigured
        }
        let client = clientFactory(baseURL)

        let data: Data
        do {
            switch variant {
            case .gridThumb:
                data = try await client.thumbnailData(id: immichID, size: .thumbnail)
            case .viewerPreview:
                data = try await client.thumbnailData(id: immichID, size: .preview)
            case .fullResolution:
                data = try await client.originalData(id: immichID)
            }
        } catch ImmichError.unauthorized {
            await confirmCredentialRejected(using: client)
            throw ImmichError.unauthorized
        }

        guard let image = cache.store(data, for: key, downsamplingTo: Self.maxPixelSize(variant)) else {
            throw ImmichError.decoding("thumbnail was not a decodable image")
        }
        return image
    }

    /// Expires the session only once an account-level call is refused too.
    ///
    /// Sync is the only other place that notices a dead token, and it runs rarely, so without
    /// this every uncached photo failed silently until the next launch. The check is needed
    /// because `ImmichClient` reports 401 and 403 alike, and an asset endpoint can refuse one
    /// asset — an API key without `asset.view` — while the credential itself is fine; expiring
    /// on that would delete a working key. Concurrent failures share one check.
    func confirmCredentialRejected(using client: ImmichClient) async {
        let check: Task<Void, Never> = lock.withLock {
            if let credentialCheck { return credentialCheck }
            let task = Task { [onCredentialRejected] in
                do {
                    _ = try await client.me()
                } catch ImmichError.unauthorized {
                    onCredentialRejected()
                } catch {}
            }
            credentialCheck = task
            return task
        }
        await check.value
        lock.withLock {
            if credentialCheck == check { credentialCheck = nil }
        }
    }

    func clearCache() { cache.removeAll() }
    func cacheSize() -> Int { cache.currentDiskSize() }

    private static func variantKey(_ variant: ImageVariant) -> String {
        switch variant {
        case .gridThumb: return "thumb"
        case .viewerPreview: return "preview"
        case .fullResolution: return "original"
        }
    }

    private static func maxPixelSize(_ variant: ImageVariant) -> CGFloat? {
        switch variant {
        case let .gridThumb(pointSize, scale):
            return max(pointSize.width, pointSize.height) * scale
        case .viewerPreview:
            return 2048
        case .fullResolution:
            return nil
        }
    }
}
