import Foundation
import Photos

/// Result of a batch action, reported per asset so partial failures stay visible (§11).
struct ActionOutcome {
    var succeeded: [AssetID] = []
    var failures: [(id: AssetID, error: Error)] = []
    /// Rotate only: kinds with no registered rotator yet (D10).
    var skippedUnsupported: [AssetID] = []

    var isCompleteSuccess: Bool { failures.isEmpty && skippedUnsupported.isEmpty }
    var firstError: Error? { failures.first?.error }
}

/// What a delete would actually do, so the UI can pick the right confirmation copy (D11).
struct DeletePlan {
    var localOnly: [AssetID] = []
    var remoteOnly: [AssetID] = []
    var both: [AssetID] = []

    var total: Int { localOnly.count + remoteOnly.count + both.count }
    /// Purely local deletions rely on the system's own confirmation sheet; anything touching
    /// the server gets an in-app confirmation first.
    var needsInAppConfirmation: Bool { !remoteOnly.isEmpty || !both.isEmpty }
}

/// Single entry point for rotate and delete, used by both the viewer toolbar and the grid's
/// multi-select toolbar (DESIGN.md §11).
///
/// Operates on 1..n assets uniformly, dispatches rotation per `MediaKind`, and reports
/// per-asset outcomes so the UI can surface partial failure rather than a blanket error.
actor PhotoActionService {
    private let timelineStore: TimelineStore
    private let resolver: PHAssetResolver
    private let editor: LocalAssetEditor
    private let registry: RotatorRegistry
    private let imageLoader: ImageLoader

    /// Batch work runs a few at a time: enough to hide latency, not enough to contend with
    /// scrolling (§14 P6).
    private let maxConcurrency = 3

    init(timelineStore: TimelineStore,
         resolver: PHAssetResolver,
         editor: LocalAssetEditor,
         registry: RotatorRegistry = .v1,
         imageLoader: ImageLoader) {
        self.timelineStore = timelineStore
        self.resolver = resolver
        self.editor = editor
        self.registry = registry
        self.imageLoader = imageLoader
    }

    nonisolated func canRotate(_ kind: MediaKind) -> Bool { registry.canRotate(kind) }

    // MARK: - Rotate (requirement 10)

    func rotate(ids: [AssetID], clockwise: Bool) async -> ActionOutcome {
        var outcome = ActionOutcome()
        var work: [(Asset, any AssetRotator)] = []

        for id in ids {
            guard let asset = await timelineStore.asset(for: id) else {
                outcome.failures.append((id, RotationError.assetUnavailable))
                continue
            }
            guard let rotator = registry.rotator(for: asset.stub.kind) else {
                outcome.skippedUnsupported.append(id)
                continue
            }
            work.append((asset, rotator))
        }

        guard !work.isEmpty else { return outcome }

        let results = await withTaskGroup(of: (AssetID, Error?).self) { group -> [(AssetID, Error?)] in
            var running = 0
            var index = 0
            var collected: [(AssetID, Error?)] = []

            func addNext() {
                guard index < work.count else { return }
                let (asset, rotator) = work[index]
                index += 1
                running += 1
                group.addTask { [weak self] in
                    guard let self else { return (asset.id, RotationError.assetUnavailable) }
                    do {
                        try await self.rotateOne(asset: asset, rotator: rotator, clockwise: clockwise)
                        return (asset.id, nil)
                    } catch {
                        return (asset.id, error)
                    }
                }
            }

            for _ in 0..<min(maxConcurrency, work.count) { addNext() }
            while running > 0, let result = await group.next() {
                running -= 1
                collected.append(result)
                addNext()
            }
            return collected
        }

        var rotatedStubs: [AssetStub] = []
        for (id, error) in results {
            if let error {
                outcome.failures.append((id, error))
            } else {
                outcome.succeeded.append(id)
                if let stub = await timelineStore.asset(for: id)?.stub {
                    // Dimensions swap on a quarter turn; publishing the updated stub keeps grid
                    // tiles and the viewer's aspect-fit correct without a full rebuild.
                    rotatedStubs.append(AssetStub(id: stub.id,
                                                  captureDate: stub.captureDate,
                                                  hasLocal: stub.hasLocal,
                                                  hasRemote: stub.hasRemote,
                                                  kind: stub.kind,
                                                  durationSeconds: stub.durationSeconds,
                                                  pixelWidth: stub.pixelHeight,
                                                  pixelHeight: stub.pixelWidth))
                }
            }
        }

        if !rotatedStubs.isEmpty {
            await timelineStore.applyChange(.update(rotatedStubs))
        }
        invalidateCaches(for: outcome.succeeded)
        return outcome
    }

    private func rotateOne(asset: Asset, rotator: any AssetRotator, clockwise: Bool) async throws {
        guard let localIdentifier = asset.localIdentifier,
              let phAsset = resolver.resolve(localIdentifier) else {
            throw RotationError.assetUnavailable
        }
        try await editor.applyRotation(asset: phAsset, clockwise: clockwise, rotator: rotator)
        // M7: the remote facet is rotated here too — download original,
        // rotator.rotateRemoteOriginal, then PUT /api/assets/{id}/original.
    }

    // MARK: - Delete (requirement 10)

    func deletePlan(ids: [AssetID]) async -> DeletePlan {
        var plan = DeletePlan()
        for id in ids {
            guard let stub = await timelineStore.asset(for: id)?.stub else { continue }
            switch (stub.hasLocal, stub.hasRemote) {
            case (true, true): plan.both.append(id)
            case (true, false): plan.localOnly.append(id)
            case (false, true): plan.remoteOnly.append(id)
            case (false, false): break
            }
        }
        return plan
    }

    /// Deletes everywhere the asset exists (D11). Local deletions go through one change request
    /// so iOS shows a single confirmation for the batch; the user can still cancel there, which
    /// is why nothing is removed from the timeline until PhotoKit reports success.
    func delete(ids: [AssetID]) async -> ActionOutcome {
        var outcome = ActionOutcome()
        var localIdentifiers: [String] = []

        for id in ids {
            guard let asset = await timelineStore.asset(for: id) else {
                outcome.failures.append((id, RotationError.assetUnavailable))
                continue
            }
            if let localIdentifier = asset.localIdentifier {
                localIdentifiers.append(localIdentifier)
            }
            // M5: collect Immich ids here and issue one DELETE /api/assets for them.
        }

        let phAssets = resolver.resolve(localIdentifiers).values.map { $0 }
        guard !phAssets.isEmpty else { return outcome }

        let failedIDs = Set(outcome.failures.map(\.id))
        let attempted = ids.filter { !failedIDs.contains($0) }

        do {
            try await editor.delete(assets: Array(phAssets))
            outcome.succeeded = attempted
            // PhotoKit's change notification also removes these, but applying directly keeps
            // the grid in step on the same runloop turn.
            await timelineStore.applyChange(.remove(attempted))
            invalidateCaches(for: attempted)
        } catch let error as NSError
            where error.domain == PHPhotosErrorDomain
            && error.code == PHPhotosError.userCancelled.rawValue {
            // The user declined the system confirmation; nothing changed and nothing failed.
        } catch is CancellationError {
            // Same, surfaced as a Swift cancellation.
        } catch {
            for id in attempted { outcome.failures.append((id, error)) }
        }
        return outcome
    }

    // MARK: - Cache invalidation

    private func invalidateCaches(for ids: [AssetID]) {
        let localIdentifiers = ids.compactMap { $0.localIdentifier }
        guard !localIdentifiers.isEmpty else { return }
        resolver.invalidate(localIdentifiers)
        imageLoader.resetCaches()
    }
}
