import UIKit

/// Two-tier cache for remote renditions: NSCache in memory, LRU on disk (DESIGN.md D13).
///
/// Decoding happens here, downsampled through ImageIO, so grid cells only ever receive a
/// ready-to-set `UIImage` (§14 P3).
final class RemoteThumbnailCache: @unchecked Sendable {
    private let memory = NSCache<NSString, UIImage>()
    private let disk: DiskCache

    init(byteLimit: Int = 500 * 1024 * 1024) {
        disk = DiskCache(name: "remote-thumbnails", byteLimit: byteLimit)
        memory.countLimit = 400
        // NSCache evicts on memory pressure; the count limit just bounds steady-state usage.
    }

    /// Memory-only lookup — safe to call on the main thread during scrolling without any disk I/O.
    func memoryImage(for key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    /// Reads encoded bytes from disk and decodes/downsamples them for `memoryKey`. Call off-main.
    func diskImage(for diskKey: String, memoryKey: String, downsamplingTo pixelSize: CGFloat?) -> UIImage? {
        guard let data = disk.data(for: diskKey) else { return nil }
        guard let image = Self.decode(data, maxPixelSize: pixelSize) else { return nil }
        memory.setObject(image, forKey: memoryKey as NSString)
        return image
    }

    /// Stores the encoded bytes under `diskKey` and returns the decoded image (cached in memory
    /// under `memoryKey`), downsampled when a target size is given.
    @discardableResult
    func store(_ data: Data, diskKey: String, memoryKey: String, downsamplingTo pixelSize: CGFloat?) -> UIImage? {
        disk.store(data, for: diskKey)
        guard let image = Self.decode(data, maxPixelSize: pixelSize) else { return nil }
        memory.setObject(image, forKey: memoryKey as NSString)
        return image
    }

    func removeAll() {
        memory.removeAllObjects()
        disk.removeAll()
    }

    /// ImageIO downsampling: decodes straight to the needed size rather than allocating the
    /// full-resolution bitmap first.
    static func decode(_ data: Data, maxPixelSize: CGFloat?) -> UIImage? {
        guard let maxPixelSize else { return UIImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return UIImage(data: data) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data) }
        return UIImage(cgImage: cgImage)
    }

    static func key(immichID: String, variant: String) -> String {
        "\(immichID)/\(variant)"
    }
}
