import SwiftUI
import BackgroundTasks

/// Exists solely to register the background-task identifier, which must happen before the app
/// finishes launching — earlier than any SwiftUI scene or `AppEnvironment` (D12).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundTaskRegistrar.registerAtLaunch(identifier: SyncEngine.backgroundTaskIdentifier)
        return true
    }
}

@main
struct OnlyDavesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                env.startup.sceneDidEnterBackground()
            case .active:
                env.startup.refreshAuthorization()
                env.startup.sceneDidBecomeActive()
            default:
                break
            }
        }
    }
}
