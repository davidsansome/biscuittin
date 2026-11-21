import Foundation

/// Bounded LRU cache on disk, used for remote thumbnails and previews (DESIGN.md D13).
///
/// Eviction is by last-access time and runs off the caller's thread. The cache is disposable
/// by design: losing it costs a re-download, never correctness, so failures are logged and
/// swallowed rather than propagated into the image path.
final class DiskCache: @unchecked Sendable {
    private let directory: URL
    private let byteLimit: Int
    private let io = DispatchQueue(label: "dev.biscuittin.diskcache", qos: .utility)
    private var hasCreatedDirectory = false
    private var isTrimScheduled = false
    private let lock = NSLock()

    init(name: String, byteLimit: Int = 500 * 1024 * 1024) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("BiscuitTin", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        self.byteLimit = byteLimit
    }

    func data(for key: String) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // Touch for LRU ordering off the caller's thread; failure only degrades eviction quality.
        io.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return data
    }

    func store(_ data: Data, for key: String) {
        let url = fileURL(for: key)
        io.async { [weak self] in
            guard let self else { return }
            self.ensureDirectoryExists()
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Log.immich.debug("Disk cache write failed: \(error.localizedDescription, privacy: .public)")
            }
            self.scheduleTrim()
        }
    }

    func removeAll() {
        io.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.directory)
            self.hasCreatedDirectory = false
            self.ensureDirectoryExists()
        }
    }

    // MARK: - Internals

    /// Runs on `io`. Defers filesystem I/O out of `init` (D19).
    private func ensureDirectoryExists() {
        guard !hasCreatedDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hasCreatedDirectory = true
    }

    private func fileURL(for key: String) -> URL {
        // Keys contain '/' (asset id + variant), so hash rather than sanitise.
        //
        // Must be a *stable* hash: Swift seeds `hashValue` randomly per process, so using it
        // here would give every launch different filenames and the disk cache would never
        // survive a restart.
        directory.appendingPathComponent(Self.stableHash(key))
    }

    /// FNV-1a: deterministic across launches, and cheap enough for the image path.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 36)
    }

    private func scheduleTrim() {
        lock.lock()
        let alreadyScheduled = isTrimScheduled
        isTrimScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }

        io.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.isTrimScheduled = false; self.lock.unlock()
            self.trim()
        }
    }

    private struct Entry {
        let url: URL
        let size: Int
        let accessed: Date
    }

    private func contents() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return [] }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
            return Entry(url: url,
                         size: values.fileSize ?? 0,
                         accessed: values.contentModificationDate ?? .distantPast)
        }
    }

    private func trim() {
        var entries = contents()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }

        // Oldest access first.
        entries.sort { $0.accessed < $1.accessed }
        for entry in entries {
            guard total > byteLimit else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
        Log.immich.debug("Disk cache trimmed to \(total) bytes")
    }
}
