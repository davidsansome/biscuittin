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
    private var hasStarted = false

    init(localLibrary: LocalLibraryService, timelineStore: TimelineStore) {
        self.localLibrary = localLibrary
        self.timelineStore = timelineStore
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
            // Publish an authoritative empty index so a stale boot cache stops showing
            // photos the app can no longer read.
            await timelineStore.startLive()
            return
        }

        phase = .buildingIndex
        await timelineStore.startLive()
        phase = .ready

        // M5 hooks in here: RemoteLibraryService.deltaSync()
        // M6 hooks in here: SyncEngine.kick()
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
