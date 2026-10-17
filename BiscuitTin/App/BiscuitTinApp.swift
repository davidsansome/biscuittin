import SwiftUI
import BackgroundTasks

/// Registers the background-task identifiers, which must happen before the app finishes
/// launching — earlier than any SwiftUI scene (D12) — and owns the environment.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Built here rather than as the app's `@StateObject` so that it exists on a background
    /// launch — to run a BGTask, or to hear how uploads ended — when no scene connects.
    /// Construction does no I/O (D19), so building it this early costs the first frame nothing.
    private(set) lazy var environment = AppEnvironment()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        for identifier in SyncEngine.backgroundTaskIdentifiers {
            BackgroundTaskRegistrar.registerAtLaunch(identifier: identifier)
        }
        // Connects the task and upload handlers before iOS can deliver either.
        _ = environment
        return true
    }

    /// iOS relaunches the app with this when background uploads end while it is not running.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.sessionIdentifier else { return completionHandler() }
        BackgroundUploader.shared.handleEvents(completion: completionHandler)
    }
}

@main
struct BiscuitTinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var env: AppEnvironment { appDelegate.environment }

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
