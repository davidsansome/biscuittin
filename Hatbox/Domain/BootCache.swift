import Foundation

/// Persisted snapshot of the timeline index, used to paint the grid at launch before
/// PhotoKit or SQLite are touched (DESIGN.md D19).
///
/// Deliberately a single flat binary file rather than a database table: the launch path
/// wants one sequential read with no SQLite warm-up. The format is versioned, and any
/// mismatch, truncation or corruption falls back to an empty result so the caller simply
/// takes the normal (slower) path.
final class BootCache {
    struct Payload {
        let grouping: Grouping
        let stubs: [AssetStub]
    }

    private enum Format {
        static let magic: UInt32 = 0x4F44_4243 // "ODBC"
        /// v2 added per-stub coordinates for the map (§20). A version bump discards the
        /// old cache rather than misreading it; the live index repopulates within a frame.
        static let version: UInt32 = 2
        static let headerSize = 16
        /// Fixed-size portion of a record; the UTF-8 identifier follows it.
        /// Fixed portion of one record; the variable-length id follows it.
        /// 24 through format v1, plus 8 for the v2 coordinate pair.
        static let recordFixedSize = 32
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.hatbox.bootcache", qos: .utility)

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: false))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("Hatbox", isDirectory: true)
                .appendingPathComponent("timeline-index.bin")
        }
    }

    // MARK: - Reading

    /// Loads the cached index. Returns nil when absent or unusable — never throws at the caller.
    func load() -> Payload? {
        Signposts.interval(Signposts.bootCacheLoad) {
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
            return Self.decode(data)
        }
    }

    static func decode(_ data: Data) -> Payload? {
        guard data.count >= Format.headerSize else { return nil }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Payload? in
            var offset = 0

            func read<T>(_ type: T.Type) -> T? {
                guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
                let value = raw.loadUnaligned(fromByteOffset: offset, as: type)
                offset += MemoryLayout<T>.size
                return value
            }

            guard let magic = read(UInt32.self), magic == Format.magic,
                  let version = read(UInt32.self), version == Format.version,
                  let groupingRaw = read(UInt8.self),
                  read(UInt8.self) != nil, read(UInt16.self) != nil, // reserved padding
                  let count = read(UInt32.self)
            else { return nil }

            let grouping: Grouping
            switch groupingRaw {
            case 0: grouping = .day
            case 1: grouping = .week
            case 2: grouping = .month
            default: return nil
            }

            var stubs = [AssetStub]()
            stubs.reserveCapacity(Int(count))

            for _ in 0..<Int(count) {
                guard offset + Format.recordFixedSize <= raw.count else { return nil }
                guard let captureSeconds = read(Double.self),
                      let duration = read(Float.self),
                      let width = read(Int32.self),
                      let height = read(Int32.self),
                      let latitude = read(Float.self),
                      let longitude = read(Float.self),
                      let flags = read(UInt8.self),
                      let kindRaw = read(UInt8.self),
                      let idLength = read(UInt16.self),
                      let kind = MediaKind(rawValue: kindRaw)
                else { return nil }

                guard offset + Int(idLength) <= raw.count else { return nil }
                let idBytes = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + Int(idLength))])
                guard let rawID = String(bytes: idBytes, encoding: .utf8) else { return nil }
                offset += Int(idLength)

                stubs.append(AssetStub(id: AssetID(raw: rawID),
                                       captureDate: Date(timeIntervalSinceReferenceDate: captureSeconds),
                                       hasLocal: flags & 0b01 != 0,
                                       hasRemote: flags & 0b10 != 0,
                                       kind: kind,
                                       durationSeconds: duration,
                                       pixelWidth: width,
                                       pixelHeight: height,
                                       latitude: latitude,
                                       longitude: longitude))
            }
            return Payload(grouping: grouping, stubs: stubs)
        }
    }

    // MARK: - Writing

    /// Serializes and writes asynchronously at utility QoS (§14 P6) so the caller never waits.
    func save(stubs: [AssetStub], grouping: Grouping) {
        let data = Self.encode(stubs: stubs, grouping: grouping)
        queue.async { [fileURL] in
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.perf.error("Boot cache write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func encode(stubs: [AssetStub], grouping: Grouping) -> Data {
        var data = Data()
        data.reserveCapacity(Format.headerSize + stubs.count * (Format.recordFixedSize + 40))

        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }

        let groupingRaw: UInt8
        switch grouping {
        case .day: groupingRaw = 0
        case .week: groupingRaw = 1
        case .month: groupingRaw = 2
        }

        append(Format.magic)
        append(Format.version)
        append(groupingRaw)
        append(UInt8(0))            // reserved
        append(UInt16(0))           // reserved
        append(UInt32(stubs.count))

        for stub in stubs {
            let idBytes = Array(stub.id.raw.utf8)
            guard idBytes.count <= Int(UInt16.max) else { continue }
            append(stub.captureDate.timeIntervalSinceReferenceDate)
            append(stub.durationSeconds)
            append(stub.pixelWidth)
            append(stub.pixelHeight)
            append(stub.latitude)
            append(stub.longitude)
            append(UInt8((stub.hasLocal ? 0b01 : 0) | (stub.hasRemote ? 0b10 : 0)))
            append(stub.kind.rawValue)
            append(UInt16(idBytes.count))
            data.append(contentsOf: idBytes)
        }
        return data
    }

    func clear() {
        queue.async { [fileURL] in try? FileManager.default.removeItem(at: fileURL) }
    }
}
