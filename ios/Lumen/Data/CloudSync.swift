import Foundation

/// Keeps the user's own lists the same on their iPhone and iPad through iCloud's key-value
/// store (`NSUbiquitousKeyValueStore`): playlists (names only, logins sync through iCloud
/// Keychain, see `Keychain`), favourites, My List, where you stopped, hidden and renamed
/// categories. Each value is the same JSON the app keeps in UserDefaults; UserDefaults stays the
/// local copy, so the app works the same without iCloud.
///
/// Needs the iCloud key-value entitlement (project.yml), which only a paid developer team can
/// sign. Apple syncs within seconds to a few minutes; the store holds up to 1 MB.
@MainActor
final class CloudSync {
    static let shared = CloudSync()
    private let cloud = NSUbiquitousKeyValueStore.default

    /// The keys that sync (UserDefaults and iCloud use the same names).
    static let keys = ["playlists", "favourites", "watchProgress", "myList", "hiddenCategories", "categoryLabels"]

    /// Saves locally and to iCloud.
    func set(_ data: Data, forKey key: String) {
        UserDefaults.standard.set(data, forKey: key)
        cloud.set(data, forKey: key)
    }

    /// Calls [changed] with the keys another device changed (on the main actor). At launch, pulls
    /// what iCloud already has; local values that iCloud doesn't have yet are sent up.
    func start(_ changed: @escaping @MainActor (_ keys: [String]) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                let updated = keys.filter { Self.keys.contains($0) && self.pull($0) }
                if !updated.isEmpty { changed(updated) }
            }
        }
        cloud.synchronize()
        var pulled: [String] = []
        for key in Self.keys {
            if cloud.data(forKey: key) != nil {
                if pull(key) { pulled.append(key) }
            } else if let local = UserDefaults.standard.data(forKey: key) {
                cloud.set(local, forKey: key)
            }
        }
        if !pulled.isEmpty { changed(pulled) }
    }

    /// Copies iCloud's value into UserDefaults. Where you stopped is merged (newest per film or
    /// episode wins) so watching on both devices loses nothing; the rest take the latest list.
    private func pull(_ key: String) -> Bool {
        guard let remote = cloud.data(forKey: key) else { return false }
        let local = UserDefaults.standard.data(forKey: key)
        guard remote != local else { return false }
        if key == "watchProgress", let local, let merged = Self.mergeProgress(local, remote) {
            UserDefaults.standard.set(merged, forKey: key)
            if merged != remote { cloud.set(merged, forKey: key) }
            return merged != local
        }
        UserDefaults.standard.set(remote, forKey: key)
        return true
    }

    private static func mergeProgress(_ a: Data, _ b: Data) -> Data? {
        let decoder = JSONDecoder()
        guard var mine = try? decoder.decode([UUID: [String: WatchProgress]].self, from: a),
              let theirs = try? decoder.decode([UUID: [String: WatchProgress]].self, from: b) else { return nil }
        for (playlist, items) in theirs {
            for (key, item) in items where (mine[playlist]?[key]?.updated ?? .distantPast) < item.updated {
                mine[playlist, default: [:]][key] = item
            }
        }
        return try? JSONEncoder().encode(mine)
    }
}
