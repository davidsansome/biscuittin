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
    let rotators: RotatorRegistry

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

        self.settings = settings
        self.localLibrary = localLibrary
        self.bootCache = bootCache
        self.assetResolver = resolver
        self.imageLoader = imageLoader
        self.database = AppDatabase()
        self.timelineStore = timelineStore
        self.assetEditor = editor
        self.rotators = rotators
        self.photoActions = PhotoActionService(timelineStore: timelineStore,
                                               resolver: resolver,
                                               editor: editor,
                                               registry: rotators,
                                               imageLoader: imageLoader)
        self.startup = StartupSequencer(localLibrary: localLibrary,
                                        timelineStore: timelineStore)
    }
}
