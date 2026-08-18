import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        GridScreen(env: env)
            .ignoresSafeArea()
    }
}
