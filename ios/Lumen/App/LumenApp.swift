import SwiftUI

@main
struct LumenApp: App {
    // One store for the whole app, handed to every screen through the environment.
    @State private var store = PlaylistStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .task { await store.loadAll() }
        }
    }
}
