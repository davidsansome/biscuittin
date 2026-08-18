import Foundation
import Photos

/// Raised when one facet succeeded and another did not, so the UI can say what actually
/// happened rather than reporting a blanket failure (§11).
enum PartialRotationError: LocalizedError {
    case serverCopyNotRotated(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .serverCopyNotRotated:
            return "Rotated on this iPhone, but the copy on Immich couldn’t be updated."
        }
    }
}

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

/// What "Free Up Space" would remove (D18).
struct FreeUpSpacePlan {
    var localIdentifiers: [String] = []
    var reclaimableBytes: Int64 = 0

    var count: Int { localIdentifiers.count }
    var isEmpty: Bool { localIdentifiers.isEmpty }

    var formattedBytes: String {
        AssetMetadata.formattedFileSize(reclaimableBytes)
    }
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

    private let remoteLibrary: RemoteLibraryService?

    init(timelineStore: TimelineStore,
         resolver: PHAssetResolver,
         editor: LocalAssetEditor,
         registry: RotatorRegistry = .v1,
         imageLoader: ImageLoader,
         remoteLibrary: RemoteLibraryService? = nil) {
        self.timelineStore = timelineStore
        self.resolver = resolver
        self.editor = editor
        self.registry = registry
        self.imageLoader = imageLoader
        self.remoteLibrary = remoteLibrary
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

    /// Rotates every facet the asset has (D10).
    ///
    /// The local edit runs first because it is the one the user sees immediately. If the server
    /// copy then fails, the local rotation still stands and the failure is reported — reporting
    /// a partial success is more honest than rolling back a correct local edit.
    private func rotateOne(asset: Asset, rotator: any AssetRotator, clockwise: Bool) async throws {
        var rotatedSomething = false

        if let localIdentifier = asset.localIdentifier,
           let phAsset = resolver.resolve(localIdentifier) {
            try await editor.applyRotation(asset: phAsset, clockwise: clockwise, rotator: rotator)
            rotatedSomething = true
        }

        if let immichID = asset.immichID, let remoteLibrary {
            do {
                try await remoteLibrary.rotateRemote(immichID: immichID,
                                                     clockwise: clockwise,
                                                     rotator: rotator)
                rotatedSomething = true
            } catch {
                if rotatedSomething {
                    throw PartialRotationError.serverCopyNotRotated(underlying: error)
                }
                throw error
            }
        }

        guard rotatedSomething else { throw RotationError.assetUnavailable }
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
        var immichIDs: [String] = []

        for id in ids {
            guard let asset = await timelineStore.fullyResolvedAsset(for: id) else {
                outcome.failures.append((id, RotationError.assetUnavailable))
                continue
            }
            if let localIdentifier = asset.localIdentifier {
                localIdentifiers.append(localIdentifier)
            }
            if let immichID = asset.immichID {
                immichIDs.append(immichID)
            }
        }

        let failedIDs = Set(outcome.failures.map(\.id))
        let attempted = ids.filter { !failedIDs.contains($0) }
        guard !attempted.isEmpty else { return outcome }

        // Local first: it is the step the user can still cancel, and cancelling must leave the
        // server copy untouched too.
        let phAssets = Array(resolver.resolve(localIdentifiers).values)
        if !phAssets.isEmpty {
            do {
                try await editor.delete(assets: phAssets)
            } catch let error as NSError
                where error.domain == PHPhotosErrorDomain
                && error.code == PHPhotosError.userCancelled.rawValue {
                return outcome
            } catch is CancellationError {
                return outcome
            } catch {
                for id in attempted { outcome.failures.append((id, error)) }
                return outcome
            }
        }

        // Then the server copy (D11): Immich moves it to its own trash, so this is recoverable.
        if !immichIDs.isEmpty, let remoteLibrary {
            do {
                try await remoteLibrary.deleteRemote(ids: immichIDs)
            } catch {
                // The local copy is already gone; report the partial failure rather than
                // pretending the whole delete succeeded.
                for id in attempted { outcome.failures.append((id, error)) }
            }
        }

        outcome.succeeded = attempted.filter { id in !outcome.failures.contains { $0.id == id } }
        // PhotoKit's change notification also removes these, but applying directly keeps the
        // grid in step on the same runloop turn.
        await timelineStore.applyChange(.remove(attempted))
        invalidateCaches(for: attempted)
        return outcome
    }

    // MARK: - Free up space (D18, M8)

    /// Candidates for reclaiming device storage: assets that verifiably exist on the server.
    ///
    /// The gate is deliberately strict — checksum-linked *and* recorded as uploaded. "Looks
    /// similar" is never sufficient justification for deleting someone's only copy.
    func freeUpSpacePlan() async -> FreeUpSpacePlan {
        guard let remoteLibrary else { return FreeUpSpacePlan() }

        let verified: [String]
        do {
            verified = try await remoteLibrary.locallyDeletableIdentifiers()
        } catch {
            return FreeUpSpacePlan()
        }
        guard !verified.isEmpty else { return FreeUpSpacePlan() }

        let assets = resolver.resolve(verified)
        var plan = FreeUpSpacePlan()
        for (identifier, asset) in assets {
            plan.localIdentifiers.append(identifier)
            plan.reclaimableBytes += LocalAssetExporter.estimatedByteCount(for: asset)
        }
        return plan
    }

    /// Deletes only the local copies. The server copies and their `remote_assets` rows are
    /// untouched; affected timeline stubs simply lose `hasLocal`.
    func freeUpSpace(_ plan: FreeUpSpacePlan) async -> ActionOutcome {
        var outcome = ActionOutcome()
        guard !plan.localIdentifiers.isEmpty else { return outcome }

        let assets = Array(resolver.resolve(plan.localIdentifiers).values)
        guard !assets.isEmpty else { return outcome }

        do {
            try await editor.delete(assets: assets)
            let ids = plan.localIdentifiers.map { AssetID.local($0) }
            outcome.succeeded = ids
            // The assets remain in the timeline, now as remote-only.
            await timelineStore.refresh()
            invalidateCaches(for: ids)
        } catch let error as NSError
            where error.domain == PHPhotosErrorDomain
            && error.code == PHPhotosError.userCancelled.rawValue {
            // Declined; nothing removed.
        } catch {
            outcome.failures.append((AssetID(raw: "free-up-space"), error))
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
