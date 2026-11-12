import SwiftUI

@main
struct PencilTutorApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ProblemListView()
                .environmentObject(env)
                .preferredColorScheme(.light)
        }
    }
}
