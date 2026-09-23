import Foundation

/// Backs the settings form (requirement 13, DESIGN.md §13.4).
///
/// Sign-in runs as a cancellable background task with inline progress; the rest of the app
/// stays usable throughout, including during the initial full sync (§14 P5).
@MainActor
final class SettingsViewModel: ObservableObject {

    @Published private(set) var serverURL: URL?
    @Published private(set) var email: String
    @Published var showsSignInFlow = false

    @Published private(set) var state: ImmichAuthSession.State
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncedCount: Int?
    @Published private(set) var lastSyncDate: Date?

    private let session: ImmichAuthSession
    private let remoteLibrary: RemoteLibraryService
    private let timelineStore: TimelineStore
    private let imageCache: RemoteImageFetcher
    private let syncEngine: SyncEngine
    private let photoActions: PhotoActionService
    private let settings: AppSettings
    private let localLibrary: LocalLibraryService
    let backupStatus: BackupStatusStore
    private var signInTask: Task<Void, Never>?

    // MARK: - Sync (requirement 14, D17)

    @Published var showsScopePrompt = false
    @Published private(set) var syncEnabled = false
    @Published private(set) var syncScope: SyncScope = .all
    @Published private(set) var outOfScopeCount = 0

    // MARK: - Free up space (D18, M8)

    @Published private(set) var freeUpSpacePlan = FreeUpSpacePlan()
    @Published var showsFreeUpSpaceConfirmation = false

    init(session: ImmichAuthSession,
         remoteLibrary: RemoteLibraryService,
         timelineStore: TimelineStore,
         imageCache: RemoteImageFetcher,
         syncEngine: SyncEngine,
         settings: AppSettings,
         backupStatus: BackupStatusStore,
         photoActions: PhotoActionService,
         localLibrary: LocalLibraryService) {
        self.session = session
        self.remoteLibrary = remoteLibrary
        self.timelineStore = timelineStore
        self.imageCache = imageCache
        self.syncEngine = syncEngine
        self.photoActions = photoActions
        self.settings = settings
        self.backupStatus = backupStatus
        self.localLibrary = localLibrary
        self.syncEnabled = settings.syncEnabled
        self.syncScope = settings.syncScope
        self.serverURL = session.baseURL
        self.email = session.email ?? ""
        self.state = session.state
        // The cursor lives in SQLite behind an actor, so it is read after init rather than
        // blocking the form's first render.
        Task { [weak self] in
            let date = await remoteLibrary.lastSyncDate()
            self?.lastSyncDate = date
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var serverVersion: String? {
        if case let .signedIn(_, version) = state { return version }
        return nil
    }

    var isExpired: Bool { state == .expired }

    var accountDescription: String {
        session.usesAPIKey ? "\(email) (API key)" : email
    }

    // MARK: - Actions

    func makeSignInFlowModel() -> SignInFlowModel {
        SignInFlowModel(
            session: session,
            asksForBackupScope: !settings.hasChosenSyncScope,
            countLocalItems: { [localLibrary] in
                // PHFetchResult.count is a query, not free on a large library.
                await Task.detached { localLibrary.fetchAllAssets().count }.value
            },
            onSignedIn: { [weak self] in self?.didSignIn() },
            onBackupChosen: { [weak self] scope in
                if let scope { self?.chooseScope(scope) } else { self?.cancelScopePrompt() }
            })
    }

    /// The flow has stored a credential; catalogue the library while the user carries on.
    private func didSignIn() {
        state = session.state
        serverURL = session.baseURL
        email = session.email ?? ""
        errorMessage = nil
        statusMessage = "Downloading library details…"
        isWorking = true

        signInTask?.cancel()
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.remoteLibrary.syncStream(reset: true) { count in
                    Task { @MainActor [weak self] in self?.syncedCount = count }
                }

                // No explicit timeline refresh here. `syncStream` already yields on the remote
                // change stream, and `TimelineStore` coalesces those into one rebuild. Calling
                // `refresh()` as well raced that delivery — the stream's yield arrived after the
                // refresh had run, re-arming the coalescer and costing a second full rebuild of
                // the whole library for no change in the result.
                self.lastSyncDate = await self.remoteLibrary.lastSyncDate()
            } catch is CancellationError {
            } catch {
                self.state = self.session.state
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.statusMessage = nil
            self.isWorking = false
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        isWorking = false
        statusMessage = nil
    }

    func signOut() {
        session.signOut()
        state = session.state
        syncedCount = nil
        Task { await timelineStore.refresh() }
    }

    /// Removes cached server metadata and thumbnails without touching the device library.
    func removeServerData() {
        Task { [weak self] in
            guard let self else { return }
            self.isWorking = true
            self.session.forgetServer()
            self.state = self.session.state
            try? await self.remoteLibrary.wipeCache()
            self.imageCache.clearCache()
            await self.timelineStore.refresh()
            self.serverURL = nil
            self.syncedCount = nil
            self.lastSyncDate = nil
            self.isWorking = false
        }
    }

    /// Toggling on asks for a scope first, unless one was chosen previously (D17).
    func setSyncEnabled(_ enabled: Bool) {
        guard enabled else {
            syncEnabled = false
            Task { await syncEngine.setEnabled(false, scope: nil) }
            return
        }
        guard settings.hasChosenSyncScope else {
            showsScopePrompt = true
            return
        }
        syncEnabled = true
        Task { await syncEngine.setEnabled(true, scope: nil) }
    }

    func chooseScope(_ scope: SyncScope) {
        showsScopePrompt = false
        syncScope = scope
        syncEnabled = true
        Task { [weak self] in
            guard let self else { return }
            await self.syncEngine.setEnabled(true, scope: scope)
            self.outOfScopeCount = await self.syncEngine.outOfScopeCount()
        }
    }

    func cancelScopePrompt() {
        showsScopePrompt = false
        syncEnabled = false
    }

    /// One-way upgrade to backing up everything (D17).
    func upgradeScopeToAll() {
        Task { [weak self] in
            guard let self else { return }
            await self.syncEngine.upgradeScopeToAll()
            self.syncScope = .all
            self.outOfScopeCount = 0
        }
    }

    func refreshSyncStatus() {
        Task { [weak self] in
            guard let self else { return }
            self.outOfScopeCount = await self.syncEngine.outOfScopeCount()
            await self.syncEngine.publishStatus(uploading: false)
            self.freeUpSpacePlan = await self.photoActions.freeUpSpacePlan()
        }
    }

    /// Deletes local copies of assets verified to exist on the server (D18).
    func performFreeUpSpace() {
        let plan = freeUpSpacePlan
        showsFreeUpSpaceConfirmation = false
        guard !plan.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            self.isWorking = true
            let outcome = await self.photoActions.freeUpSpace(plan)
            if let error = outcome.firstError {
                self.errorMessage = error.localizedDescription
            }
            self.freeUpSpacePlan = await self.photoActions.freeUpSpacePlan()
            self.isWorking = false
        }
    }

    func refreshNow() {
        Task { [weak self] in
            guard let self else { return }
            self.isWorking = true
            self.statusMessage = "Refreshing…"
            do {
                try await self.remoteLibrary.syncStream(reset: false)
                await self.timelineStore.refresh()
                self.lastSyncDate = await self.remoteLibrary.lastSyncDate()
            } catch {
                // A 401 has already marked the session expired; show the re-sign-in row.
                self.state = self.session.state
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.statusMessage = nil
            self.isWorking = false
        }
    }
}
