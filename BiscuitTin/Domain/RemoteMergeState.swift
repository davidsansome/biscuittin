import Foundation

extension RemoteMergeData {
    /// The merged timeline, from scratch: local assets, marked where they have a server copy,
    /// plus the server copies whose local twin is not present. `RemoteMergeState.patch` must
    /// agree with this for every asset it touches.
    func merged(withLocal localStubs: [AssetStub]) -> TimelineIndex {
        var present = Set<String>()
        present.reserveCapacity(localStubs.count)
        let marked = localStubs.map { stub -> AssetStub in
            guard let localIdentifier = stub.id.localIdentifier else { return stub }
            present.insert(localIdentifier)
            // An asset with a server copy is one asset with two facets, not two rows.
            return linkedLocalIdentifiers.contains(localIdentifier)
                ? stub.withFacets(hasLocal: true, hasRemote: true)
                : stub
        }

        // PhotoKit sorts by creationDate, but assets with no creation date fall back to
        // `.distantPast` and can land out of order; `replaceAll` sorts only if needed.
        var index = TimelineIndex()
        index.replaceAll(marked)
        let remoteOnly = remoteOnlyStubs(presentLocalIdentifiers: present)
        if !remoteOnly.isEmpty {
            index.insert(remoteOnly)
        }
        return index
    }
}

/// The server half of the merged timeline, which `TimelineStore` keeps in memory so a server
/// change can be applied to the timeline directly rather than by rebuilding it.
///
/// Mirrors what `RemoteLibraryService` has cached: every non-trashed server asset, and every
/// complete local↔server link.
struct RemoteMergeState {
    /// Non-trashed server stubs, newest first.
    private(set) var stubs = TimelineIndex()
    private(set) var stubsByID: [String: AssetStub] = [:]
    private(set) var localIdentifierByImmichID: [String: String] = [:]
    /// Server assets linked to each local asset. A local stub has a server facet while its set
    /// is non-empty, and removing that local asset promotes these remote stubs back into the
    /// timeline.
    private var immichIDsByLocalIdentifier: [String: Set<String>] = [:]

    /// Above this many changed assets, the bulk `TimelineIndex` operations are cheaper than one
    /// binary-search splice per asset.
    private static let maxSplicedChanges = 64

    init(stubs: [AssetStub], links: [String: String]) {
        self.stubs.replaceAll(stubs)
        stubsByID.reserveCapacity(stubs.count)
        for stub in stubs {
            if let immichID = stub.id.immichID { stubsByID[immichID] = stub }
        }
        localIdentifierByImmichID = links
        for (immichID, localIdentifier) in links {
            immichIDsByLocalIdentifier[localIdentifier, default: []].insert(immichID)
        }
    }

    func isLinked(_ localIdentifier: String) -> Bool {
        immichIDsByLocalIdentifier[localIdentifier] != nil
    }

    /// Server stubs linked to `localIdentifier` (used when the local copy is deleted so its
    /// surviving server copy can be promoted back into the timeline).
    func remoteStubs(linkedTo localIdentifier: String) -> [AssetStub] {
        guard let ids = immichIDsByLocalIdentifier[localIdentifier] else { return [] }
        return ids.compactMap { stubsByID[$0] }
    }

    /// Immich IDs linked to `localIdentifier` (used when a linked local asset is inserted so any
    /// standalone remote stub for it is hidden).
    func linkedImmichIDs(for localIdentifier: String) -> Set<String> {
        immichIDsByLocalIdentifier[localIdentifier] ?? []
    }

    var mergeData: RemoteMergeData {
        var data = RemoteMergeData()
        data.stubs = stubs.stubs
        data.localIdentifierByImmichID = localIdentifierByImmichID
        data.linkedLocalIdentifiers = Set(immichIDsByLocalIdentifier.keys)
        return data
    }

    /// What an `update` touched, for `patch` to carry into the timeline.
    struct Transition {
        var immichIDs = Set<String>()
        /// The touched assets' stubs before the update, which say where to find them.
        var previousStubs: [String: AssetStub] = [:]
        /// Local assets whose link changed, or that are linked to a touched asset.
        var localIdentifiers = Set<String>()
    }

    /// Replaces what is known about some server assets. Each of `stubIDs` takes its row from
    /// `fresh`, where an id with no row there has no visible row; each of `linkIDs` takes its
    /// link from `links` in the same way.
    mutating func update(stubsFor stubIDs: Set<String>, stubs fresh: [AssetStub],
                         linksFor linkIDs: Set<String>, links: [String: String]) -> Transition {
        var transition = Transition(immichIDs: stubIDs.union(linkIDs))

        var freshByID = [String: AssetStub]()
        for stub in fresh {
            if let immichID = stub.id.immichID { freshByID[immichID] = stub }
        }
        var removed = [AssetStub]()
        var inserted = [AssetStub]()
        for immichID in stubIDs {
            let old = stubsByID[immichID]
            let new = freshByID[immichID]
            if let old { transition.previousStubs[immichID] = old }
            guard old != new else { continue }
            if let old { removed.append(old) }
            if let new { inserted.append(new) }
            stubsByID[immichID] = new
        }
        if removed.count + inserted.count <= Self.maxSplicedChanges {
            for stub in removed {
                if let position = stubs.position(of: stub.id, capturedAt: stub.captureDate) {
                    stubs.remove(at: position)
                }
            }
            inserted.forEach { stubs.insertAbsent($0) }
        } else {
            stubs.remove(removed.map(\.id))
            stubs.insert(inserted)
        }

        for immichID in linkIDs {
            let old = localIdentifierByImmichID[immichID]
            let new = links[immichID]
            guard old != new else { continue }
            if let old {
                transition.localIdentifiers.insert(old)
                if var ids = immichIDsByLocalIdentifier[old] {
                    ids.remove(immichID)
                    immichIDsByLocalIdentifier[old] = ids.isEmpty ? nil : ids
                }
            }
            if let new {
                transition.localIdentifiers.insert(new)
                immichIDsByLocalIdentifier[new, default: []].insert(immichID)
            }
            localIdentifierByImmichID[immichID] = new
        }
        // Whether a server copy shows depends on its local twin being present.
        for immichID in transition.immichIDs {
            if let localIdentifier = localIdentifierByImmichID[immichID] {
                transition.localIdentifiers.insert(localIdentifier)
            }
        }
        return transition
    }

    struct PatchResult: Equatable {
        var changed = false
        /// Asset IDs whose content or facet flags changed under the same identity, so the UI
        /// knows to reconfigure their cells.
        var reconfiguredIDs: [AssetID] = []
    }

    /// Brings `index` in line with this state for the assets `transition` touched, giving what
    /// `RemoteMergeData.merged` would. Idempotent, so it is safe after a rebuild that already
    /// saw this state.
    ///
    /// `localCaptureDates` gives, for each of `transition.localIdentifiers` that PhotoKit still
    /// has, the date its stub is indexed under.
    func patch(_ index: inout TimelineIndex, for transition: Transition,
               localCaptureDates: [String: Date]) -> PatchResult {
        var result = PatchResult()

        var presentLocals = Set<String>()
        for localIdentifier in transition.localIdentifiers {
            guard let date = localCaptureDates[localIdentifier],
                  let position = index.position(of: .local(localIdentifier), capturedAt: date)
            else { continue }
            presentLocals.insert(localIdentifier)
            let stub = index.stubs[position]
            let linked = isLinked(localIdentifier)
            if stub.hasRemote != linked {
                index.replace(at: position, with: stub.withFacets(hasLocal: stub.hasLocal, hasRemote: linked))
                result.changed = true
                result.reconfiguredIDs.append(stub.id)
            }
        }

        for immichID in transition.immichIDs {
            let id = AssetID.remote(immichID)
            let current = stubsByID[immichID]
            // Shown under its old date, or its new one if a rebuild got there first.
            var existing: Int?
            for date in [transition.previousStubs[immichID]?.captureDate, current?.captureDate] {
                guard existing == nil, let date else { continue }
                existing = index.position(of: id, capturedAt: date)
            }
            let hidden = localIdentifierByImmichID[immichID].map(presentLocals.contains) ?? false
            let desired = hidden ? nil : current

            if let existing, let desired {
                if index.stubs[existing] == desired { continue }
                index.remove(at: existing)
                index.insertAbsent(desired)
                result.changed = true
                result.reconfiguredIDs.append(id)
            } else if let existing {
                index.remove(at: existing)
                result.changed = true
            } else if let desired {
                index.insertAbsent(desired)
                result.changed = true
            }
        }
        return result
    }
}
