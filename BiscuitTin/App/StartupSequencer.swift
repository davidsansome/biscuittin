import Foundation
import Photos

/// Orders the work that happens *after* the first frame is on screen (DESIGN.md D19).
///
/// The launch path is: paint the boot-cache snapshot → first frame → this sequencer runs, in
/// priority order: PhotoKit authorization, live index, then (M5) remote delta sync and (M6)
/// the upload engine. Nothing here may run before the grid has rendered.
@MainActor
final class StartupSequencer: ObservableObject {

    enum Phase: Equatable {
        case waitingForFirstFrame
        case requestingAccess
        case buildingIndex
        case ready
        case accessDenied
    }

    @Published private(set) var phase: Phase = .waitingForFirstFrame
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined

    private let localLibrary: LocalLibraryService
    private let timelineStore: TimelineStore
    private let remoteLibrary: RemoteLibraryService
    private let session: ImmichAuthSession
    private let syncEngine: SyncEngine
    private let searchIndexer: SearchIndexer
    private var hasStarted = false

    init(localLibrary: LocalLibraryService,
         timelineStore: TimelineStore,
         remoteLibrary: RemoteLibraryService,
         session: ImmichAuthSession,
         syncEngine: SyncEngine,
         searchIndexer: SearchIndexer) {
        self.localLibrary = localLibrary
        self.timelineStore = timelineStore
        self.remoteLibrary = remoteLibrary
        self.session = session
        self.syncEngine = syncEngine
        self.searchIndexer = searchIndexer
        self.authorizationStatus = localLibrary.authorizationStatus
    }

    /// Called by the grid once its first frame has actually been presented.
    func firstFrameDidRender() {
        guard !hasStarted else { return }
        hasStarted = true
        Log.perf.info("First frame rendered; starting deferred init")

        Task { await runStartupSequence() }
    }

    private func runStartupSequence() async {
        phase = .requestingAccess
        let status = await localLibrary.requestAccess()
        authorizationStatus = status

        guard status == .authorized || status == .limited else {
            phase = .accessDenied
            // Publish an authoritative index anyway: a configured server may still have photos
            // to show, and a stale boot cache must stop showing local ones we can't read.
            await timelineStore.startLive()
            await runRemoteSync()
            return
        }

        phase = .buildingIndex
        await timelineStore.startLive()
        phase = .ready

        await runRemoteSync()

        // Upload sync runs last: it is the lowest-priority work and must never delay the
        // grid or the metadata refresh (§14 P6).
        await syncEngine.publishStatus(uploading: false)
        syncEngine.scheduleBackgroundTask()
        await syncEngine.kick()

        // Search indexing is the lowest-priority work in the app (§19.2): it runs only once
        // the grid is up, remote metadata is current, and uploads have been kicked off.
        await searchIndexer.run()
    }

    /// Catches up with the server after the first frame. Failures are logged, never surfaced
    /// as a blocking error — the grid is already usable from cached metadata (§15 offline).
    ///
    /// `syncStream` reports hard deletes as explicit events in the same call (D9), so unlike the
    /// old paged delta sync this is the whole catch-up — no separate reconciliation sweep needed.
    private func runRemoteSync() async {
        guard session.isConfigured else { return }
        do {
            try await remoteLibrary.syncStream(reset: false)
        } catch is CancellationError {
            return
        } catch {
            Log.immich.error("Sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Foreground refresh, so returning to the app picks up server-side changes.
    func sceneDidBecomeActive() {
        guard hasStarted else { return }
        Task {
            await runRemoteSync()
            await syncEngine.kick()
        }
    }

    /// Pull-to-refresh on the grid (D9). Cheap enough to call directly now that a sync is a
    /// bounded delta fetch rather than a full page-through of the library.
    func pullToRefresh() async {
        guard hasStarted else { return }
        await runRemoteSync()
        await timelineStore.refresh()
    }

    /// Re-checks authorization after the user returns from the Settings app.
    func refreshAuthorization() {
        let status = localLibrary.authorizationStatus
        guard status != authorizationStatus else { return }
        authorizationStatus = status
        if status == .authorized || status == .limited {
            phase = .buildingIndex
            Task {
                await timelineStore.startLive()
                await timelineStore.refresh()
                phase = .ready
            }
        }
    }

    /// Scene moved to the background: make sure the freshest index survives to next launch.
    func sceneDidEnterBackground() {
        Task { await timelineStore.writeBootCache() }
    }
}
