import SwiftUI

@main
struct PencilTutorApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(env.account)
                .environmentObject(env.memory)
                .preferredColorScheme(.light)
        }
    }
}
