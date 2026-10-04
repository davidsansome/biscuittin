import Foundation

/// Partners' libraries, as browsable timelines of their own (§22).
///
/// Deliberately separate from `TimelineStore`: a partner's photos are someone else's, so they
/// take no part in the merged timeline, facet linking, search, backup or any edit. Everything
/// here reads the cache that `RemoteLibraryService.syncStream` fills, so a partner's library
/// opens instantly and offline, exactly like the user's own server photos.
final class PartnerLibrary: Sendable {
    private let remoteLibrary: RemoteLibraryService

    init(remoteLibrary: RemoteLibraryService) {
        self.remoteLibrary = remoteLibrary
    }

    /// Everyone sharing with the signed-in user, by name. Empty when signed out.
    func partners() async -> [Partner] {
        (try? await remoteLibrary.partners()) ?? []
    }

    /// A partner's library, grouped like the home grid. Yields once straight away from the
    /// cache, then again after every sync that touches partner data, until cancelled.
    func snapshots(of partner: Partner, grouping: Grouping) -> AsyncStream<TimelineSnapshot> {
        let remoteLibrary = remoteLibrary
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // Listening before the first read, so a sync landing in between is not missed.
                var changes = NotificationCenter.default.notifications(
                    named: RemoteLibraryService.partnersDidChangeNotification).makeAsyncIterator()
                continuation.yield(await Self.snapshot(of: partner, grouping: grouping, from: remoteLibrary))
                while await changes.next() != nil {
                    continuation.yield(await Self.snapshot(of: partner, grouping: grouping, from: remoteLibrary))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func snapshot(of partner: Partner, grouping: Grouping,
                                 from remoteLibrary: RemoteLibraryService) async -> TimelineSnapshot {
        let stubs = (try? await remoteLibrary.partnerStubs(ownerID: partner.id)) ?? []
        return makeSnapshot(stubs, grouping: grouping)
    }

    /// - Parameter stubs: newest first, as `partnerStubs` returns them.
    static func makeSnapshot(_ stubs: [AssetStub], grouping: Grouping) -> TimelineSnapshot {
        TimelineSnapshot(grouping: grouping,
                         buckets: TimelineBucketer().buckets(from: stubs, grouping: grouping),
                         totalCount: stubs.count,
                         provenance: .live)
    }
}
