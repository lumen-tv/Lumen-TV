import SwiftUI

@main
struct LumenApp: App {
    #if os(iOS)
    // Lets the players turn the iPhone sideways (`ScreenOrientation`).
    @UIApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    #else
    // Mac: quits when the window closes, keeps the window size (Mac/MacApp.swift).
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
    // One store for the whole app, handed to every screen through the environment.
    @State private var store = PlaylistStore()

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .task { await store.loadAll() }
        }
        #else
        // One window (a second copy of Lumen would open a second connection to the provider,
        // which most allow only one of). Its content runs up under the title bar, as on the TV.
        Window("Lumen", id: "main") {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 600)
                .task { await store.loadAll() }
                .task { await MacUpdates.shared.check() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        .commands { LumenCommands() }
        #endif
    }
}
