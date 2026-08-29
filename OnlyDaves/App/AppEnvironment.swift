import SwiftUI

/// Composition root. Builds and wires every service exactly once.
///
/// **Contract (D19): construction performs no I/O.** No PhotoKit query, no database open, no
/// boot-cache read happens here — only object graph assembly — so that `@main` returning is
/// never what delays the first frame.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let localLibrary: LocalLibraryService
    let bootCache: BootCache
    let assetResolver: PHAssetResolver
    let imageLoader: ImageLoader
    let database: AppDatabase
    let timelineStore: TimelineStore
    let startup: StartupSequencer
    let assetEditor: LocalAssetEditor
    let photoActions: PhotoActionService
    let shareService: ShareService
    let rotators: RotatorRegistry
    let embeddingStore: EmbeddingStore
    let clipEncoder: CLIPEncoder
    let searchEngine: SearchEngine
    let searchIndexer: SearchIndexer
    let immichSession: ImmichAuthSession
    let remoteLibrary: RemoteLibraryService
    let remoteImages: RemoteImageFetcher
    let exporter: LocalAssetExporter
    let syncEngine: SyncEngine
    let backupStatus: BackupStatusStore

    init() {
        let settings = AppSettings()
        let localLibrary = LocalLibraryService()
        let bootCache = BootCache()
        let resolver = PHAssetResolver()
        let imageLoader = ImageLoader(resolver: resolver)
        let timelineStore = TimelineStore(localLibrary: localLibrary,
                                          bootCache: bootCache,
                                          settings: settings)
        let editor = LocalAssetEditor()
        let rotators = RotatorRegistry.v1
        let database = AppDatabase()
        let immichSession = ImmichAuthSession()
        let remoteLibrary = RemoteLibraryService(database: database, session: immichSession)
        let remoteImages = RemoteImageFetcher(session: immichSession,
                                              cache: RemoteThumbnailCache())
        let exporter = LocalAssetExporter()
        let backupStatus = BackupStatusStore()
        let syncEngine = SyncEngine(database: database,
                                    session: immichSession,
                                    localLibrary: localLibrary,
                                    resolver: resolver,
                                    exporter: exporter,
                                    remoteLibrary: remoteLibrary,
                                    settings: settings,
                                    status: backupStatus)

        self.settings = settings
        self.localLibrary = localLibrary
        self.bootCache = bootCache
        self.assetResolver = resolver
        self.imageLoader = imageLoader
        self.database = database
        self.timelineStore = timelineStore
        self.assetEditor = editor
        self.rotators = rotators
        self.immichSession = immichSession
        self.remoteLibrary = remoteLibrary
        self.remoteImages = remoteImages
        self.exporter = exporter
        self.syncEngine = syncEngine
        self.backupStatus = backupStatus
        self.photoActions = PhotoActionService(timelineStore: timelineStore,
                                               resolver: resolver,
                                               editor: editor,
                                               registry: rotators,
                                               imageLoader: imageLoader,
                                               remoteLibrary: remoteLibrary)
        self.shareService = ShareService(timelineStore: timelineStore,
                                         resolver: resolver,
                                         remoteImages: remoteImages,
                                         exporter: exporter)

        let embeddingStore = EmbeddingStore(database: database)
        let clipEncoder = CLIPEncoder()
        self.embeddingStore = embeddingStore
        self.clipEncoder = clipEncoder
        self.searchEngine = SearchEngine(encoder: clipEncoder, store: embeddingStore)
        self.searchIndexer = SearchIndexer(store: embeddingStore,
                                           encoder: clipEncoder,
                                           timelineStore: timelineStore,
                                           resolver: resolver,
                                           remoteImages: remoteImages)
        self.startup = StartupSequencer(localLibrary: localLibrary,
                                        timelineStore: timelineStore,
                                        remoteLibrary: remoteLibrary,
                                        session: immichSession,
                                        syncEngine: syncEngine,
                                        searchIndexer: self.searchIndexer)

        // Wiring that would otherwise be an initialisation cycle. Still zero I/O (D19).
        imageLoader.attachRemoteFetcher(remoteImages)
        syncEngine.connectBackgroundHandler()
        Task { await timelineStore.attach(remoteLibrary: remoteLibrary) }
    }

    @MainActor
    func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(session: immichSession,
                          remoteLibrary: remoteLibrary,
                          timelineStore: timelineStore,
                          imageCache: remoteImages,
                          syncEngine: syncEngine,
                          settings: settings,
                          backupStatus: backupStatus,
                          photoActions: photoActions)
    }
}
