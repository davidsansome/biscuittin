import Foundation
import Photos

/// PhotoKit access: authorization, fetching, and change observation.
///
/// Deliberately *not* `@MainActor` (a documented deviation from the first design draft):
/// every call here touches the photo database, and the performance contract forbids that
/// work on the main thread (§14 P3). PhotoKit's own APIs are thread-safe.
final class LocalLibraryService: NSObject, @unchecked Sendable {

    /// Library mutations observed from PhotoKit. Consumed by `TimelineStore`, which turns
    /// them into incremental `TimelineChange`s rather than full rebuilds (D20).
    nonisolated let changes: AsyncStream<PHChange>
    private let changesContinuation: AsyncStream<PHChange>.Continuation
    private var isObserving = false
    private let lock = NSLock()

    override init() {
        let (stream, continuation) = AsyncStream<PHChange>.makeStream(bufferingPolicy: .bufferingNewest(8))
        changes = stream
        changesContinuation = continuation
        super.init()
    }

    deinit {
        if isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
        changesContinuation.finish()
    }

    // MARK: - Authorization

    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var hasAnyAccess: Bool {
        let status = authorizationStatus
        return status == .authorized || status == .limited
    }

    /// Requests read/write access. Safe to call when already determined — PhotoKit
    /// returns the existing status without showing UI.
    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        let current = authorizationStatus
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Fetching

    /// Images and videos only (D3), newest first. Returns PhotoKit's lazy fetch result;
    /// callers enumerate it off the main thread.
    func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let options = Self.timelineFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: options)
    }

    private static func timelineFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        return options
    }

    /// Whether `fetchAllAssets` would include this asset. An asset fetched by identifier is
    /// checked here as well as by the fetch options, which are not documented to apply the
    /// hidden and burst filters to an explicit identifier list.
    private static func belongsInTimeline(_ asset: PHAsset) -> Bool {
        (asset.mediaType == .image || asset.mediaType == .video)
            && !asset.isHidden
            && (asset.burstIdentifier == nil || asset.representsBurst)
    }

    func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    func assets(for localIdentifiers: [String]) -> [PHAsset] {
        guard !localIdentifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var assets = [PHAsset]()
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: - Persistent changes

    struct Delta {
        /// Assets inserted or updated since the token that still belong in the timeline.
        var upserted: [PHAsset] = []
        /// Identifiers deleted since the token, or changed so they no longer belong (hidden,
        /// say). May name assets the caller never had.
        var removedIdentifiers: [String] = []
    }

    /// Marks the library's current position in its change history. Take it *before*
    /// enumerating: replaying from a token that is too old is harmless, one that is too new
    /// loses changes.
    var currentChangeToken: PHPersistentChangeToken {
        PHPhotoLibrary.shared().currentChangeToken
    }

    /// The net asset changes since `token`, or nil when PhotoKit can no longer describe them
    /// (an expired token, most often) and the caller must enumerate the whole library.
    func delta(since token: PHPersistentChangeToken) -> Delta? {
        var touched = Set<String>()
        var deleted = Set<String>()
        do {
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
                let details = try change.changeDetails(for: .asset)
                touched.formUnion(details.insertedLocalIdentifiers)
                touched.formUnion(details.updatedLocalIdentifiers)
                deleted.formUnion(details.deletedLocalIdentifiers)
            }
        } catch {
            Log.timeline.error("Persistent changes unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        touched.subtract(deleted)
        var delta = Delta(removedIdentifiers: Array(deleted))
        guard !touched.isEmpty else { return delta }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(touched),
                                         options: Self.timelineFetchOptions())
        var kept = Set<String>()
        result.enumerateObjects { asset, _, _ in
            guard Self.belongsInTimeline(asset) else { return }
            delta.upserted.append(asset)
            kept.insert(asset.localIdentifier)
        }
        delta.removedIdentifiers.append(contentsOf: touched.subtracting(kept))
        return delta
    }

    // MARK: - Observation

    func startObserving() {
        lock.lock(); defer { lock.unlock() }
        guard !isObserving else { return }
        isObserving = true
        PHPhotoLibrary.shared().register(self)
    }
}

extension LocalLibraryService: PHPhotoLibraryChangeObserver {
    /// Called by PhotoKit on a private background queue.
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        changesContinuation.yield(changeInstance)
    }
}

// MARK: - PHAsset bridging

extension AssetStub {
    init(_ asset: PHAsset) {
        let kind: MediaKind
        if asset.mediaType == .video {
            kind = .video
        } else if asset.mediaSubtypes.contains(.photoLive) {
            kind = .livePhoto
        } else {
            kind = .image
        }

        let coordinate = asset.location?.coordinate
        self.init(id: .local(asset.localIdentifier),
                  captureDate: asset.creationDate ?? asset.modificationDate ?? .distantPast,
                  hasLocal: true,
                  hasRemote: false,
                  kind: kind,
                  durationSeconds: kind == .video ? Float(asset.duration) : 0,
                  pixelWidth: Int32(clamping: asset.pixelWidth),
                  pixelHeight: Int32(clamping: asset.pixelHeight),
                  latitude: coordinate.map { Float($0.latitude) } ?? .nan,
                  longitude: coordinate.map { Float($0.longitude) } ?? .nan)
    }
}
