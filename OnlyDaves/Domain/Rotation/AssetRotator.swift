import Foundation
import Photos

/// Strategy for physically rotating one kind of media (DESIGN.md D10).
///
/// Rotation is dispatched by `MediaKind`, not hard-coded to images: v1 registers only
/// `ImageRotator`, and M9 adds `VideoRotator` (lossless transform remux) and
/// `LivePhotoRotator` without any change to callers. Kinds with no registered rotator are
/// reported as skipped rather than failing.
protocol AssetRotator: Sendable {
    var supportedKind: MediaKind { get }

    /// Produces the rotated rendition for a PhotoKit content-editing session.
    /// - Returns: a temporary file the caller moves into the editing output.
    func rotateLocal(input: PHContentEditingInput, clockwise: Bool) async throws -> URL

    /// Produces the replacement file for a downloaded Immich original (M7).
    func rotateRemoteOriginal(fileURL: URL, clockwise: Bool) async throws -> URL
}

enum RotationError: LocalizedError {
    case unsupportedMediaKind(MediaKind)
    case missingImageSource
    case renderFailed
    case assetUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedMediaKind: return "This item can’t be rotated yet."
        case .missingImageSource: return "The original file couldn’t be read."
        case .renderFailed: return "The rotated image couldn’t be created."
        case .assetUnavailable: return "This item is no longer available."
        }
    }
}

/// Looks up the rotator for a media kind. The set of registered rotators is what defines
/// which kinds are rotatable in a given release.
struct RotatorRegistry: Sendable {
    private let rotators: [MediaKind: any AssetRotator]

    init(rotators: [any AssetRotator]) {
        var map = [MediaKind: any AssetRotator]()
        for rotator in rotators { map[rotator.supportedKind] = rotator }
        self.rotators = map
    }

    /// All media kinds are rotatable as of M9.
    static let v1 = RotatorRegistry(rotators: [ImageRotator(), VideoRotator(), LivePhotoRotator()])

    func rotator(for kind: MediaKind) -> (any AssetRotator)? { rotators[kind] }
    func canRotate(_ kind: MediaKind) -> Bool { rotators[kind] != nil }
}
