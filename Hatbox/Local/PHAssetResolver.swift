import Foundation
import Photos

/// Resolves `AssetStub`s back to `PHAsset`s for image requests.
///
/// The timeline index holds only lightweight stubs (D6), so the image pipeline needs a way
/// back to PhotoKit objects. Fetching one identifier at a time is a photo-database query per
/// cell, so this batches lookups and keeps a bounded LRU of recently used assets covering the
/// visible window plus the prefetch margin.
final class PHAssetResolver: @unchecked Sendable {
    private let capacity: Int
    private var cache: [String: PHAsset] = [:]
    private var recency: [String] = []
    private let lock = NSLock()

    init(capacity: Int = 600) {
        self.capacity = capacity
    }

    func cached(_ localIdentifier: String) -> PHAsset? {
        lock.lock(); defer { lock.unlock() }
        guard let asset = cache[localIdentifier] else { return nil }
        touchLocked(localIdentifier)
        return asset
    }

    /// Batch-resolves identifiers, hitting PhotoKit only for the ones not already cached.
    func resolve(_ localIdentifiers: [String]) -> [String: PHAsset] {
        guard !localIdentifiers.isEmpty else { return [:] }

        var found = [String: PHAsset]()
        var missing = [String]()

        lock.lock()
        for identifier in localIdentifiers {
            if let asset = cache[identifier] {
                found[identifier] = asset
                touchLocked(identifier)
            } else {
                missing.append(identifier)
            }
        }
        lock.unlock()

        guard !missing.isEmpty else { return found }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        var fetched = [(String, PHAsset)]()
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            fetched.append((asset.localIdentifier, asset))
        }

        lock.lock()
        for (identifier, asset) in fetched {
            cache[identifier] = asset
            touchLocked(identifier)
            found[identifier] = asset
        }
        trimLocked()
        lock.unlock()

        return found
    }

    func resolve(_ localIdentifier: String) -> PHAsset? {
        resolve([localIdentifier])[localIdentifier]
    }

    func invalidate(_ localIdentifiers: [String]) {
        lock.lock(); defer { lock.unlock() }
        for identifier in localIdentifiers {
            cache.removeValue(forKey: identifier)
            if let idx = recency.firstIndex(of: identifier) { recency.remove(at: idx) }
        }
    }

    // MARK: - LRU bookkeeping (caller holds the lock)

    private func touchLocked(_ identifier: String) {
        if let idx = recency.firstIndex(of: identifier) { recency.remove(at: idx) }
        recency.append(identifier)
    }

    private func trimLocked() {
        guard cache.count > capacity else { return }
        let overflow = cache.count - capacity
        for identifier in recency.prefix(overflow) { cache.removeValue(forKey: identifier) }
        recency.removeFirst(min(overflow, recency.count))
    }
}
