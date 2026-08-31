import Foundation
import Photos

/// Resolves assets to items a `UIActivityViewController` can share (requirement 6, share button).
///
/// A local asset is exported to a temp file via `LocalAssetExporter` — the same streaming export
/// already proven for uploads — and handed over as `NSItemProvider(contentsOf:)`. Two earlier
/// attempts both failed:
///  * A raw `PHAsset` looked reasonable but isn't `NSItemProviderWriting`; every real share
///    target declined it, leaving only Quick Note, which accepts any object at all.
///  * Writing the resource's bytes through a lazy `registerFileRepresentation` loadHandler got
///    real targets to show up, but on a write failure it still handed back the (empty)
///    destination URL — so every target received a blank file with the error silently lost
///    inside `NSItemProvider`'s own machinery.
/// Reusing the exporter fixes both: the file is fully written *before* the item provider is ever
/// constructed, so a failure throws instead of producing a blank share, and
/// `LocalAssetExporter.primaryResource` already resolves to the edited rendition when one exists
/// (this app's own rotation, in particular), not the pre-edit original.
///
/// A remote-only image fetches the full-resolution rendition and shares the decoded `UIImage`
/// instead — a concrete image type every share target already understands. Remote-only video
/// isn't shareable yet — `VideoPlaybackProvider` has no client for Immich's `/video/playback`
/// endpoint (§10.1, M5 note), so there is nothing to share.
actor ShareService {
    enum ShareError: Error, LocalizedError {
        case remoteVideoUnsupported
        case unresolvable

        var errorDescription: String? {
            switch self {
            case .remoteVideoUnsupported: "This video hasn’t been downloaded yet, so it can’t be shared."
            case .unresolvable: "Couldn’t find that item."
            }
        }
    }

    private let timelineStore: TimelineStore
    private let resolver: PHAssetResolver
    private let remoteImages: RemoteImageFetching
    private let exporter: LocalAssetExporter

    init(timelineStore: TimelineStore,
        resolver: PHAssetResolver,
        remoteImages: RemoteImageFetching,
        exporter: LocalAssetExporter) {
        self.timelineStore = timelineStore
        self.resolver = resolver
        self.remoteImages = remoteImages
        self.exporter = exporter
    }

    /// Best-effort, mirroring `ActionOutcome`'s partial-success shape used by rotate and delete:
    /// one unresolvable item in a multi-select share should not block the rest.
    func activityItems(for ids: [AssetID]) async -> (items: [Any], failures: [(id: AssetID, error: Error)]) {
        var items = [Any]()
        var failures = [(id: AssetID, error: Error)]()

        for id in ids {
            do {
                items.append(try await activityItem(for: id))
            } catch {
                failures.append((id, error))
            }
        }
        return (items, failures)
    }

    private func activityItem(for id: AssetID) async throws -> Any {
        guard let asset = await timelineStore.asset(for: id) else { throw ShareError.unresolvable }

        if let localIdentifier = asset.localIdentifier, let phAsset = resolver.resolve(localIdentifier) {
            return try await shareProvider(for: phAsset)
        }

        guard let immichID = asset.immichID else { throw ShareError.unresolvable }
        guard asset.stub.kind != .video else { throw ShareError.remoteVideoUnsupported }
        return try await remoteImages.image(immichID: immichID, variant: .fullResolution)
    }

    private func shareProvider(for phAsset: PHAsset) async throws -> NSItemProvider {
        let export = try await exporter.export(asset: phAsset)

        // The exporter names its temp file for upload bookkeeping ("upload-<uuid>-<name>"); a
        // share target that surfaces the filename (Mail, Files, AirDrop) should see the real one.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(export.filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: export.fileURL, to: destination)

        guard let provider = NSItemProvider(contentsOf: destination) else { throw ShareError.unresolvable }
        return provider
    }
}
