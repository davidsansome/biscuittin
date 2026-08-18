import UIKit
import Photos

/// Which rendition of an asset is wanted (DESIGN.md §10.1).
enum ImageVariant {
    case gridThumb(pointSize: CGSize, scale: CGFloat)
    case viewerPreview
    case fullResolution

    /// Target size in pixels for PhotoKit.
    func targetSize(screenScale: CGFloat, screenSize: CGSize) -> CGSize {
        switch self {
        case let .gridThumb(pointSize, scale):
            return CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        case .viewerPreview:
            return CGSize(width: screenSize.width * screenScale, height: screenSize.height * screenScale)
        case .fullResolution:
            return PHImageManagerMaximumSize
        }
    }

    var contentMode: PHImageContentMode {
        if case .gridThumb = self { return .aspectFill }
        return .aspectFit
    }
}

/// Cancellable handle for an in-flight image request.
///
/// The PhotoKit request id is only known after the asset has been resolved off the main
/// thread, so the token is a mutable box: cancelling before resolution sets a flag the
/// resolver checks, cancelling afterwards cancels the real request.
final class ImageRequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var remoteTask: Task<Void, Never>?
    private(set) var isCancelled = false

    fileprivate func attach(_ id: PHImageRequestID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isCancelled else { return false }
        requestID = id
        return true
    }

    fileprivate func attach(remote task: Task<Void, Never>) {
        lock.lock()
        let cancelled = isCancelled
        remoteTask = task
        lock.unlock()
        if cancelled { task.cancel() }
    }

    fileprivate func cancel(using manager: PHImageManager) {
        lock.lock()
        isCancelled = true
        let id = requestID
        let task = remoteTask
        requestID = nil
        remoteTask = nil
        lock.unlock()
        if let id { manager.cancelImageRequest(id) }
        task?.cancel()
    }
}

/// Unified image loading for grid cells and the viewer.
///
/// A plain thread-safe class rather than an actor (documented deviation): grid cells issue
/// and cancel requests on every reuse during a fast flick, and an actor hop on that path
/// costs responsiveness for no safety benefit — `PHImageManager` is already thread-safe.
/// The contract that matters is §14 P3: decoding never happens on the main thread, and cells
/// only ever receive a ready-to-set `UIImage`.
final class ImageLoader: @unchecked Sendable {
    private let manager = PHCachingImageManager()
    private let resolver: PHAssetResolver
    private let workQueue = DispatchQueue(label: "dev.onlydaves.imageloader",
                                          qos: .userInitiated,
                                          attributes: .concurrent)
    /// Screen metrics are captured up front and refreshed from the UI on layout, so that
    /// background request paths never have to hop to the main thread to size a request.
    private var screenMetrics: ScreenMetrics
    private let metricsLock = NSLock()

    @MainActor
    init(resolver: PHAssetResolver) {
        self.resolver = resolver
        let screen = UIScreen.main
        self.screenMetrics = ScreenMetrics(scale: screen.scale, size: screen.bounds.size)
        manager.allowsCachingHighQualityImages = false
    }

    /// Connected once an Immich server is configured. Nil means local-only, which is a fully
    /// supported mode (D12).
    private var storedRemoteFetcher: RemoteImageFetching?

    private var remoteFetcher: RemoteImageFetching? {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return storedRemoteFetcher
    }

    func attachRemoteFetcher(_ fetcher: RemoteImageFetching) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        storedRemoteFetcher = fetcher
    }

    /// Called from the grid/viewer on layout so viewer-sized requests track the real bounds.
    func updateScreenMetrics(scale: CGFloat, size: CGSize) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        screenMetrics = ScreenMetrics(scale: scale, size: size)
    }

    /// Requests an image. `completion` runs on the main queue and may be called more than
    /// once — PhotoKit delivers a fast degraded rendition first, then the full-quality one.
    @discardableResult
    func requestImage(for stub: AssetStub,
                      variant: ImageVariant,
                      completion: @escaping (UIImage?, _ isDegraded: Bool) -> Void) -> ImageRequestToken {
        let token = ImageRequestToken()

        guard let localIdentifier = stub.id.localIdentifier, stub.hasLocal else {
            // Remote-only asset: serve from cache synchronously when possible, otherwise fetch.
            if let immichID = stub.id.immichID, let remote = remoteFetcher {
                if let cached = remote.cachedImage(immichID: immichID, variant: variant) {
                    DispatchQueue.main.async { completion(cached, false) }
                    return token
                }
                let task = Task { [weak self] in
                    guard self != nil else { return }
                    do {
                        let image = try await remote.image(immichID: immichID, variant: variant)
                        guard !Task.isCancelled, !token.isCancelled else { return }
                        await MainActor.run { completion(image, false) }
                    } catch {
                        guard !Task.isCancelled else { return }
                        await MainActor.run { completion(nil, false) }
                    }
                }
                token.attach(remote: task)
                return token
            }
            DispatchQueue.main.async { completion(nil, false) }
            return token
        }

        let screen = mainScreenMetrics()
        workQueue.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            guard let asset = self.resolver.resolve(localIdentifier) else {
                DispatchQueue.main.async { completion(nil, false) }
                return
            }
            guard !token.isCancelled else { return }

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let id = self.manager.requestImage(
                for: asset,
                targetSize: variant.targetSize(screenScale: screen.scale, screenSize: screen.size),
                contentMode: variant.contentMode,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                guard !cancelled, !token.isCancelled else { return }
                if Thread.isMainThread {
                    completion(image, degraded)
                } else {
                    DispatchQueue.main.async { completion(image, degraded) }
                }
            }

            if !token.attach(id) {
                self.manager.cancelImageRequest(id)
            }
        }
        return token
    }

    func cancel(_ token: ImageRequestToken?) {
        token?.cancel(using: manager)
    }

    // MARK: - Prefetching (driven by UICollectionViewDataSourcePrefetching)

    func startPrefetch(_ stubs: [AssetStub], variant: ImageVariant) {
        let identifiers = stubs.compactMap { $0.hasLocal ? $0.id.localIdentifier : nil }
        guard !identifiers.isEmpty else { return }
        let screen = mainScreenMetrics()
        let size = variant.targetSize(screenScale: screen.scale, screenSize: screen.size)

        workQueue.async { [weak self] in
            guard let self else { return }
            let assets = Array(self.resolver.resolve(identifiers).values)
            guard !assets.isEmpty else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            self.manager.startCachingImages(for: assets,
                                            targetSize: size,
                                            contentMode: variant.contentMode,
                                            options: options)
        }
    }

    func cancelPrefetch(_ stubs: [AssetStub], variant: ImageVariant) {
        let identifiers = stubs.compactMap { $0.hasLocal ? $0.id.localIdentifier : nil }
        guard !identifiers.isEmpty else { return }
        let screen = mainScreenMetrics()
        let size = variant.targetSize(screenScale: screen.scale, screenSize: screen.size)

        workQueue.async { [weak self] in
            guard let self else { return }
            let assets = Array(self.resolver.resolve(identifiers).values)
            guard !assets.isEmpty else { return }
            self.manager.stopCachingImages(for: assets,
                                           targetSize: size,
                                           contentMode: variant.contentMode,
                                           options: nil)
        }
    }

    /// Called when the grid's column count changes: cached renditions at the old size are
    /// no longer useful.
    func resetCaches() {
        workQueue.async { [weak self] in
            self?.manager.stopCachingImagesForAllAssets()
        }
    }

    // MARK: - Helpers

    private struct ScreenMetrics { let scale: CGFloat; let size: CGSize }

    private func mainScreenMetrics() -> ScreenMetrics {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return screenMetrics
    }
}
