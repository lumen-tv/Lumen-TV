import SwiftUI
import UIKit

/// The menu on Lumen's Home Screen icon (press and hold it): "Continue watching" (the film or
/// episode you were last on, by name) and "Search".
///
/// iOS hands the chosen item to the window's scene delegate, which SwiftUI apps don't have by
/// default, so `LumenAppDelegate` adds a small one (`LumenSceneDelegate`). It parks the choice
/// here as `pending`; `RootView` watches it and acts once the app is showing.
@MainActor
@Observable
final class QuickActions {
    static let shared = QuickActions()

    enum Action: Equatable {
        case search
        /// A Continue watching entry: its key (`m:<id>`/`e:<id>`) and its playlist.
        case resume(key: String, playlistID: UUID)
    }

    var pending: Action?

    private static let searchType = "com.hayat.lumen.search"
    private static let resumeType = "com.hayat.lumen.resume"

    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch item.type {
        case Self.searchType:
            pending = .search
        case Self.resumeType:
            guard let key = item.userInfo?["key"] as? String,
                  let playlistID = (item.userInfo?["playlist"] as? String).flatMap(UUID.init(uuidString:)) else { return false }
            pending = .resume(key: key, playlistID: playlistID)
        default:
            return false
        }
        return true
    }

    /// Rewrites the icon's menu, when the app goes to the background: the latest unfinished film
    /// or episode (or the next episode of a finished one), then Search.
    func refresh(store: PlaylistStore) {
        var items: [UIApplicationShortcutItem] = []
        if let playlist = store.selected {
            let latest = (store.continueWatching(.movie, in: playlist) + store.continueWatching(.series, in: playlist))
                .max { $0.updated < $1.updated }
            if let latest {
                let name = latest.finished ? (latest.next ?? latest.title) : latest.title
                items.append(UIApplicationShortcutItem(
                    type: Self.resumeType,
                    localizedTitle: "Continue watching",
                    localizedSubtitle: name,
                    icon: UIApplicationShortcutIcon(systemImageName: "play.fill"),
                    userInfo: ["key": latest.key as NSString, "playlist": playlist.id.uuidString as NSString]
                ))
            }
        }
        items.append(UIApplicationShortcutItem(
            type: Self.searchType,
            localizedTitle: "Search",
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass"),
            userInfo: nil
        ))
        UIApplication.shared.shortcutItems = items
    }
}

/// Receives the icon menu's choice: at launch (`willConnectTo`) or while Lumen was already
/// running in the background (`performActionFor`). SwiftUI still makes and runs the window.
@MainActor
final class LumenSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { QuickActions.shared.handle(item) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActions.shared.handle(shortcutItem))
    }
}
