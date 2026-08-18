import SwiftUI

@main
struct OnlyDavesApp: App {
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
            default:
                break
            }
        }
    }
}
