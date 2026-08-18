import Foundation

/// Backs the settings form (requirement 13, DESIGN.md §13.4).
///
/// Sign-in runs as a cancellable background task with inline progress; the rest of the app
/// stays usable throughout, including during the initial full sync (§14 P5).
@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var serverURLText: String
    @Published var email: String
    @Published var password: String = ""

    @Published private(set) var state: ImmichAuthSession.State
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncedCount: Int?
    @Published private(set) var lastSyncDate: Date?
    @Published var showsInsecureWarning = false

    private let session: ImmichAuthSession
    private let remoteLibrary: RemoteLibraryService
    private let timelineStore: TimelineStore
    private let imageCache: RemoteImageFetcher
    private let syncEngine: SyncEngine
    private let settings: AppSettings
    let backupStatus: BackupStatusStore
    private var signInTask: Task<Void, Never>?

    // MARK: - Sync (requirement 14, D17)

    @Published var showsScopePrompt = false
    @Published private(set) var syncEnabled = false
    @Published private(set) var syncScope: SyncScope = .all
    @Published private(set) var outOfScopeCount = 0

    init(session: ImmichAuthSession,
         remoteLibrary: RemoteLibraryService,
         timelineStore: TimelineStore,
         imageCache: RemoteImageFetcher,
         syncEngine: SyncEngine,
         settings: AppSettings,
         backupStatus: BackupStatusStore) {
        self.session = session
        self.remoteLibrary = remoteLibrary
        self.timelineStore = timelineStore
        self.imageCache = imageCache
        self.syncEngine = syncEngine
        self.settings = settings
        self.backupStatus = backupStatus
        self.syncEnabled = settings.syncEnabled
        self.syncScope = settings.syncScope
        self.serverURLText = session.baseURL?.absoluteString ?? ""
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

    var canSignIn: Bool {
        !isWorking && !serverURLText.isEmpty && !email.isEmpty && !password.isEmpty
    }

    // MARK: - Actions

    func signIn() {
        guard let url = ImmichAuthSession.normalizeServerURL(serverURLText) else {
            errorMessage = ImmichError.invalidURL.localizedDescription
            return
        }
        // Plain HTTP off the local network needs explicit acknowledgement (D14).
        if ImmichAuthSession.isInsecureNonLocal(url), !showsInsecureWarning {
            showsInsecureWarning = true
            return
        }
        performSignIn(url: url)
    }

    func confirmInsecureAndSignIn() {
        showsInsecureWarning = false
        guard let url = ImmichAuthSession.normalizeServerURL(serverURLText) else { return }
        performSignIn(url: url)
    }

    private func performSignIn(url: URL) {
        errorMessage = nil
        statusMessage = "Connecting…"
        isWorking = true
        let credentials = (email: email, password: password)

        signInTask?.cancel()
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.signIn(baseURL: url,
                                              email: credentials.email,
                                              password: credentials.password)
                self.password = ""
                self.state = self.session.state
                self.serverURLText = url.absoluteString
                self.statusMessage = "Downloading library details…"

                try await self.remoteLibrary.fullSync { count in
                    Task { @MainActor [weak self] in self?.syncedCount = count }
                }

                await self.timelineStore.refresh()
                self.lastSyncDate = await self.remoteLibrary.lastSyncDate()
                self.statusMessage = nil
                self.isWorking = false
            } catch is CancellationError {
                self.isWorking = false
                self.statusMessage = nil
            } catch {
                self.state = self.session.state
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.statusMessage = nil
                self.isWorking = false
            }
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
        password = ""
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
            self.serverURLText = ""
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
        }
    }

    func refreshNow() {
        Task { [weak self] in
            guard let self else { return }
            self.isWorking = true
            self.statusMessage = "Refreshing…"
            do {
                try await self.remoteLibrary.deltaSync()
                await self.timelineStore.refresh()
                self.lastSyncDate = await self.remoteLibrary.lastSyncDate()
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.statusMessage = nil
            self.isWorking = false
        }
    }
}
