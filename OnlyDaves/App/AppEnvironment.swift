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

    init() {
        let settings = AppSettings()
        let localLibrary = LocalLibraryService()
        let bootCache = BootCache()
        let resolver = PHAssetResolver()

        self.settings = settings
        self.localLibrary = localLibrary
        self.bootCache = bootCache
        self.assetResolver = resolver
        self.imageLoader = ImageLoader(resolver: resolver)
        self.database = AppDatabase()
        self.timelineStore = TimelineStore(localLibrary: localLibrary,
                                           bootCache: bootCache,
                                           settings: settings)
        self.startup = StartupSequencer(localLibrary: localLibrary,
                                        timelineStore: timelineStore)
    }
}
