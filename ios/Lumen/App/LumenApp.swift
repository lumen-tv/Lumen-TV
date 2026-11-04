import SwiftUI

@main
struct LumenApp: App {
    // Lets the players turn the iPhone sideways (`ScreenOrientation`).
    @UIApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
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
