import Foundation

/// Stable app-level identity for one asset, regardless of where it lives (DESIGN.md D5).
/// The raw value is namespaced by the facet that introduced it, so a local-only and a
/// remote-only asset can never collide.
struct AssetID: Hashable, Codable, CustomStringConvertible {
    let raw: String

    init(raw: String) { self.raw = raw }

    static func local(_ localIdentifier: String) -> AssetID { AssetID(raw: "L:" + localIdentifier) }
    static func remote(_ immichID: String) -> AssetID { AssetID(raw: "R:" + immichID) }

    /// Non-nil when this identity was minted from a PhotoKit asset.
    var localIdentifier: String? {
        raw.hasPrefix("L:") ? String(raw.dropFirst(2)) : nil
    }

    /// Non-nil when this identity was minted from an Immich asset.
    var immichID: String? {
        raw.hasPrefix("R:") ? String(raw.dropFirst(2)) : nil
    }

    var description: String { raw }
}

/// Distinct media kinds, modelled from day one so video and Live Photo rotation
/// can land in M9 without touching the domain model (DESIGN.md D3).
enum MediaKind: UInt8, Codable, Hashable {
    case image = 0
    case livePhoto = 1
    case video = 2

    var isRotatableInV1: Bool { self == .image }
}

/// Where a given asset physically lives.
enum AssetFacet: Hashable {
    case local(phLocalIdentifier: String)
    case remote(immichID: String)
}

/// Lightweight record held in the in-memory timeline index (DESIGN.md D6).
/// Also the boot-cache serialization unit (D19), so keep it small and flat.
struct AssetStub: Hashable {
    let id: AssetID
    let captureDate: Date
    let hasLocal: Bool
    let hasRemote: Bool
    let kind: MediaKind
    /// Zero for images and Live Photos.
    let durationSeconds: Float
    let pixelWidth: Int32
    let pixelHeight: Int32

    var isRemoteOnly: Bool { hasRemote && !hasLocal }

    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// Returns a copy with backing-store flags replaced (used by incremental updates).
    func withFacets(hasLocal: Bool, hasRemote: Bool) -> AssetStub {
        AssetStub(id: id,
                  captureDate: captureDate,
                  hasLocal: hasLocal,
                  hasRemote: hasRemote,
                  kind: kind,
                  durationSeconds: durationSeconds,
                  pixelWidth: pixelWidth,
                  pixelHeight: pixelHeight)
    }
}

/// Fully resolved asset, materialized on demand for the viewer, actions and info sheet.
struct Asset {
    let id: AssetID
    /// One or two entries; the local facet comes first when present.
    let facets: [AssetFacet]
    let stub: AssetStub

    var localIdentifier: String? {
        for facet in facets {
            if case let .local(identifier) = facet { return identifier }
        }
        return nil
    }

    var immichID: String? {
        for facet in facets {
            if case let .remote(identifier) = facet { return identifier }
        }
        return nil
    }
}
