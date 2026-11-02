import Foundation
import Observation
import UIKit
import Shared

/// A saved playlist. Only what's safe to keep in plain settings; the login is in the Keychain.
struct Playlist: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case xtream, m3u }

    let id: UUID
    var name: String
    var kind: Kind
    /// Just the host, for showing in Settings.
    var host: String
}

/// The secret half of a playlist, stored in the Keychain.
private struct PlaylistLogin: Codable {
    var server: String?
    var username: String?
    var password: String?
    var link: String?
    /// A guide link the user typed (Settings → playlist → TV guide). Kept here, not in plain
    /// settings, because such links can hold a login too.
    var guideUrl: String?
}

/// A playlist's channels, loaded from the provider by the shared Kotlin code.
struct LoadedLibrary {
    let library: LiveLibrary
    let categories: [LiveCategory]
    let channelsByCategory: [String: [LiveChannel]]
    let byKey: [String: LiveChannel]
    /// `library.channels` as a Swift array, made once: each read of the Kotlin list (and of a
    /// channel's name) crosses into Kotlin and copies the text, which added up in long lists.
    let channels: [LiveChannel]
    /// The channels' names as Swift strings, in the same order, for search.
    private let titles: [String]

    /// Channels the provider didn't put in any category.
    static let otherKey = "\u{0}other"

    init(_ library: LiveLibrary) {
        self.library = library
        let channels = library.channels
        self.channels = channels
        titles = channels.map(\.title)
        var byCategory = [String: [LiveChannel]]()
        for channel in channels {
            byCategory[channel.categoryName ?? Self.otherKey, default: []].append(channel)
        }
        channelsByCategory = byCategory
        byKey = Dictionary(channels.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        categories = library.categories
    }

    /// Channels whose name contains `text` (any case), in playlist order, at most `limit`.
    func search(_ text: String, limit: Int) -> [LiveChannel] {
        var found: [LiveChannel] = []
        for (i, title) in titles.enumerated() where title.localizedCaseInsensitiveContains(text) {
            found.append(channels[i])
            if found.count == limit { break }
        }
        return found
    }
}

/// Saved playlists and their channels. `@Observable` is SwiftUI's own observation (iOS 17+):
/// views that read a property redraw when it changes.
@MainActor
@Observable
final class PlaylistStore {
    enum LoadState { case idle, loading, loaded(LoadedLibrary), failed(String) }

    private(set) var playlists: [Playlist] = []
    private(set) var states: [UUID: LoadState] = [:]
    var selectedID: UUID?

    // The Kotlin loader. Its `suspend` functions arrive in Swift as `async throws`; Kotlin
    // wants them called from the main thread, which this @MainActor class guarantees.
    private let loader = LumenKt.makePlaylistLoader()
    private let defaultsKey = "playlists"

    /// Favourite channels per playlist, in the user's order, as stable keys (`StableKeys`): the
    /// same idea as the TV's `favourites` table, so they survive refreshes. A favourite that's
    /// missing from the playlist is kept and comes back if the channel does.
    private(set) var favouriteKeys: [UUID: [String]] = [:]
    private let favouritesKey = "favourites"

    /// The TV guide per playlist, loaded after the channels (from the panel's xmltv.php, or the
    /// M3U's url-tvg). Kept in memory only for now: it reloads at each launch.
    private(set) var guideStates: [UUID: GuideState] = [:] {
        didSet { nowNextCache.removeAll() }
    }

    /// Films and series per playlist (Xtream only), loaded after the channels.
    private(set) var vodStates: [UUID: VodState] = [:]
    /// Where you stopped in films and episodes, per playlist, keyed `m:<id>` / `e:<id>`.
    private(set) var progress: [UUID: [String: WatchProgress]] = [:]
    private let progressKey = "watchProgress"
    /// Positions saved while a film plays (every 15 s) that pages haven't been shown yet. They're
    /// written to disk at once but only reach `progress` when playback pauses or stops: changing
    /// `progress` redraws every page that shows progress (even tabs out of sight), and doing that
    /// every 15 s during playback could make the video stutter.
    @ObservationIgnored private var unpublishedProgress: [UUID: [String: WatchProgress]] = [:]
    /// The guide's now/next per channel, worked out at most once a minute (see `nowNext`).
    @ObservationIgnored private var nowNextCache: [String: (minute: Int64, value: NowNext?)] = [:]
    /// Films and series saved to My List, per playlist, newest first (provider ids survive refreshes).
    private(set) var myList: [UUID: [MyListItem]] = [:]
    private let myListKey = "myList"
    /// Hidden categories per playlist, keyed `l:<name>` (live), `m:<id>` (films), `s:<id>` (series).
    private(set) var hiddenCategories: [UUID: Set<String>] = [:]
    /// The user's names for categories, same keys. Display only: the provider's name stays the key.
    private(set) var categoryLabels: [UUID: [String: String]] = [:]
    private let hiddenKey = "hiddenCategories"
    private let labelsKey = "categoryLabels"
    @ObservationIgnored private var syncStarted = false
    @ObservationIgnored private var movieInfoCache: [String: MovieInfo] = [:]
    @ObservationIgnored private var seriesInfoCache: [String: SeriesInfo] = [:]

    init() {
        reload(CloudSync.keys)
        selectedID = playlists.first?.id
        // Another device changed a list: read it again. New playlists load their channels.
        CloudSync.shared.start { [weak self] keys in
            guard let self else { return }
            let known = Set(self.playlists.map(\.id))
            self.reload(keys)
            if self.selectedID == nil || !self.playlists.contains(where: { $0.id == self.selectedID }) {
                self.selectedID = self.playlists.first?.id
            }
            // At launch the app's own loadAll() covers it.
            if keys.contains(self.defaultsKey), self.syncStarted {
                for gone in known.subtracting(self.playlists.map(\.id)) { self.forget(gone) }
                Task { await self.loadAll() }
            }
        }
        syncStarted = true
        // Logins saved before sync existed go up to iCloud Keychain too.
        for playlist in playlists {
            if let data = Keychain.load(playlist.id.uuidString) { Keychain.save(data, for: playlist.id.uuidString) }
        }
    }

    /// Reads the saved lists from UserDefaults (CloudSync keeps them in step with iCloud).
    private func reload(_ keys: [String]) {
        func read<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard keys.contains(key), let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        if let saved = read(defaultsKey, [Playlist].self) { playlists = saved }
        if let saved = read(favouritesKey, [UUID: [String]].self) { favouriteKeys = saved }
        if let saved = read(progressKey, [UUID: [String: WatchProgress]].self) { progress = saved; unpublishedProgress = [:] }
        if let saved = read(hiddenKey, [UUID: Set<String>].self) { hiddenCategories = saved }
        if let saved = read(labelsKey, [UUID: [String: String]].self) { categoryLabels = saved }
        if let saved = read(myListKey, [UUID: [MyListItem]].self) { myList = saved }
    }

    /// A playlist removed on another device: drop what this one loaded for it.
    private func forget(_ id: UUID) {
        states[id] = nil
        guideStates[id] = nil
        vodStates[id] = nil
        deleteCache(id)
    }

    var selected: Playlist? { playlists.first { $0.id == selectedID } ?? playlists.first }

    func state(of playlist: Playlist) -> LoadState { states[playlist.id] ?? .idle }

    /// At launch: shows what was saved on the phone straight away, then refreshes whatever is
    /// missing or old in the background (like the TV app: channels and guide after 12 h, films
    /// and series after 24 h). Pull to refresh always reloads.
    func loadAll() async {
        for playlist in playlists {
            let id = playlist.id
            // The lookup tables (`LoadedLibrary`, `VodIndex`) are built in the background too:
            // tens of thousands of films took a noticeable moment on the main thread.
            if isIdle(playlist), let live = await Self.background({ LibraryCache.shared.loadLive(path: Self.cachePath(id, "live")).map(LoadedLibrary.init) }) {
                states[id] = .loaded(live)
            }
            if guideStates[id] == nil, let guide = await Self.background({ LibraryCache.shared.loadGuide(path: Self.cachePath(id, "guide")) }) {
                guideStates[id] = .loaded(guide)
            }
            if vodStates[id] == nil, let vod = await Self.background({ LibraryCache.shared.loadVod(path: Self.cachePath(id, "vod")).map(VodIndex.init) }) {
                vodStates[id] = .loaded(vod)
            }
        }
        // Channels (then the guide, which needs them) and films/series all at once: films used to
        // wait for the channels to finish first.
        await withTaskGroup(of: Void.self) { group in
            for playlist in playlists {
                let live = isIdle(playlist) || Self.isStale(playlist.id, "live", hours: 12)
                group.addTask { @MainActor in
                    if live { await self.refresh(playlist) }
                    if self.guideStates[playlist.id] == nil || Self.isStale(playlist.id, "guide", hours: 12) {
                        await self.loadGuide(playlist)
                    }
                }
                if vodStates[playlist.id] == nil || Self.isStale(playlist.id, "vod", hours: 24) {
                    group.addTask { @MainActor in await self.loadVod(playlist) }
                }
            }
        }
    }

    /// Channels, guide, films and series, all again (pull to refresh, Settings → Refresh).
    func refreshEverything(_ playlist: Playlist) async {
        await refresh(playlist)
        async let guide: Void = loadGuide(playlist)
        async let vod: Void = loadVod(playlist)
        _ = await (guide, vod)
    }

    // MARK: Saved on the phone

    /// `Library/Caches/Lumen/<playlist>-live.json` etc. (Caches: iOS may clear it when space is
    /// short, which only means a slower next start.)
    nonisolated static func cachePath(_ id: UUID, _ kind: String) -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id.uuidString)-\(kind).json").path
    }

    nonisolated static func isStale(_ id: UUID, _ kind: String, hours: Double) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath(id, kind)),
              let modified = attributes[.modificationDate] as? Date else { return true }
        return Date.now.timeIntervalSince(modified) > hours * 3600
    }

    /// Runs file work off the main thread (big playlists take a moment to read and write).
    nonisolated static func background<T>(_ work: @escaping () -> T) async -> T {
        await Task.detached(priority: .utility) { work() }.value
    }

    private func saveCache(_ id: UUID, _ kind: String, _ save: @escaping (String) throws -> Void) {
        let path = Self.cachePath(id, kind)
        Task.detached(priority: .utility) { try? save(path) }
    }

    private func deleteCache(_ id: UUID) {
        for kind in ["live", "guide", "vod"] {
            try? FileManager.default.removeItem(atPath: Self.cachePath(id, kind))
        }
    }

    private func isIdle(_ playlist: Playlist) -> Bool {
        if case .idle = state(of: playlist) { return true }
        return false
    }

    func refresh(_ playlist: Playlist) async {
        guard let login = login(for: playlist) else {
            states[playlist.id] = .failed("The login for this playlist is missing. Remove it and add it again.")
            return
        }
        // Keeps showing what's there while it reloads; only an empty screen shows "Loading".
        let hadData = isLoaded(playlist)
        if !hadData { states[playlist.id] = .loading }
        do {
            let library = try await load(login)
            let built = await Self.background { LoadedLibrary(library) }
            states[playlist.id] = .loaded(built)
            saveCache(playlist.id, "live") { try LibraryCache.shared.saveLive(library: library, path: $0) }
        } catch {
            if !hadData { states[playlist.id] = .failed(Self.message(for: error)) }
        }
    }

    private func isLoaded(_ playlist: Playlist) -> Bool {
        if case .loaded = state(of: playlist) { return true }
        return false
    }

    /// Checks the login by loading the channels, and saves the playlist only if that works.
    /// Throws an error whose message is worded for the user.
    func addXtream(name: String, server: String, username: String, password: String) async throws {
        let login = PlaylistLogin(server: server, username: username, password: password)
        try await add(name: name, kind: .xtream, login: login)
    }

    func addM3u(name: String, link: String) async throws {
        // A get.php link holds an Xtream login: store it as one (the provider may block get.php).
        if let parts = loader.xtreamLogin(link: link) {
            let login = PlaylistLogin(server: parts.server, username: parts.username, password: parts.password)
            try await add(name: name, kind: .xtream, login: login)
        } else {
            try await add(name: name, kind: .m3u, login: PlaylistLogin(link: link))
        }
    }

    private func add(name: String, kind: Playlist.Kind, login: PlaylistLogin) async throws {
        let library: LiveLibrary
        do {
            library = try await load(login)
        } catch {
            throw PlaylistError(message: Self.message(for: error))
        }
        let built = await Self.background { LoadedLibrary(library) }
        let host = Self.host(of: login)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let playlist = Playlist(id: UUID(), name: trimmed.isEmpty ? host : trimmed, kind: kind, host: host)
        store(login, for: playlist)
        playlists.append(playlist)
        states[playlist.id] = .loaded(built)
        saveCache(playlist.id, "live") { try LibraryCache.shared.saveLive(library: library, path: $0) }
        selectedID = playlist.id
        save()
        Task { await loadGuide(playlist) }
        Task { await loadVod(playlist) }
    }

    func remove(_ playlist: Playlist) {
        Keychain.delete(playlist.id.uuidString)
        favouriteKeys[playlist.id] = nil
        saveFavourites()
        vodStates[playlist.id] = nil
        guideStates[playlist.id] = nil
        progress[playlist.id] = nil
        unpublishedProgress[playlist.id] = nil
        saveProgress()
        myList[playlist.id] = nil
        saveMyList()
        hiddenCategories[playlist.id] = nil
        categoryLabels[playlist.id] = nil
        saveCategorySettings()
        deleteCache(playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        states[playlist.id] = nil
        if selectedID == playlist.id { selectedID = playlists.first?.id }
        save()
    }

    // MARK: Favourites

    func isFavourite(_ channel: LiveChannel, in playlist: Playlist) -> Bool {
        favouriteKeys[playlist.id]?.contains(channel.key) == true
    }

    func toggleFavourite(_ channel: LiveChannel, in playlist: Playlist) {
        Haptics.tap()
        var keys = favouriteKeys[playlist.id] ?? []
        if let index = keys.firstIndex(of: channel.key) {
            keys.remove(at: index)
        } else {
            keys.append(channel.key)
        }
        favouriteKeys[playlist.id] = keys
        saveFavourites()
    }

    /// The favourites that are in the playlist right now, in the user's order.
    func favourites(in playlist: Playlist) -> [LiveChannel] {
        guard case .loaded(let loaded) = state(of: playlist) else { return [] }
        return (favouriteKeys[playlist.id] ?? []).compactMap { loaded.byKey[$0] }
    }

    /// Saves a new order (or a removal) made on the shown favourites. Favourites that are
    /// missing from the playlist right now keep their place at the end.
    func setFavourites(_ shown: [LiveChannel], in playlist: Playlist) {
        let shownKeys = shown.map(\.key)
        let present = Set(favourites(in: playlist).map(\.key))
        let missing = (favouriteKeys[playlist.id] ?? []).filter { !present.contains($0) }
        favouriteKeys[playlist.id] = shownKeys + missing
        saveFavourites()
    }

    private func saveFavourites() {
        if let data = try? JSONEncoder().encode(favouriteKeys) {
            CloudSync.shared.set(data, forKey: favouritesKey)
        }
    }

    // MARK: TV guide

    func guideState(of playlist: Playlist) -> GuideState { guideStates[playlist.id] ?? .idle }

    /// The loaded guide, if there is one.
    func guide(for playlist: Playlist?) -> Guide? {
        guard let playlist, case .loaded(let guide) = guideState(of: playlist) else { return nil }
        return guide
    }

    /// What's on now and next on a channel of the selected playlist. Rows ask for this on every
    /// redraw, so the answer from the guide (Kotlin code) is kept for the rest of the minute.
    func nowNext(_ channel: LiveChannel, at date: Date = .now) -> NowNext? {
        guard let playlist = selected, let guide = guide(for: playlist) else { return nil }
        guard let tvgId = channel.tvgId else { return nil }
        let minute = Int64(date.timeIntervalSince1970) / 60
        let key = playlist.id.uuidString + "|" + tvgId
        if let hit = nowNextCache[key], hit.minute == minute { return hit.value }
        let value = guide.nowNext(tvgId: tvgId, now: Int64(date.timeIntervalSince1970))
        if nowNextCache.count > 5000 { nowNextCache.removeAll() }
        nowNextCache[key] = (minute, value)
        return value
    }

    func loadGuide(_ playlist: Playlist) async {
        guard case .loaded(let loaded) = state(of: playlist) else { return }
        let ids = loaded.library.channels.compactMap(\.tvgId)
        let now = Int64(Date.now.timeIntervalSince1970)
        let hadGuide: Bool = { if case .loaded = guideState(of: playlist) { return true }; return false }()
        if !hadGuide { guideStates[playlist.id] = .loading }
        do {
            let guide: Guide
            if let url = login(for: playlist)?.guideUrl {
                guide = try await loader.loadGuide(url: url, tvgIds: ids, now: now)
            } else if let creds = xtreamLogin(for: playlist) {
                guide = try await loader.loadXtreamGuide(
                    server: creds.server, username: creds.username, password: creds.password, tvgIds: ids, now: now
                )
            } else if let url = loaded.library.epgUrl {
                guide = try await loader.loadGuide(url: url, tvgIds: ids, now: now)
            } else {
                guideStates[playlist.id] = .unavailable
                return
            }
            guideStates[playlist.id] = .loaded(guide)
            saveCache(playlist.id, "guide") { try LibraryCache.shared.saveGuide(guide: guide, path: $0) }
        } catch {
            if !hadGuide { guideStates[playlist.id] = .failed(Self.message(for: error)) }
        }
    }

    // MARK: Films and series

    func vodState(of playlist: Playlist) -> VodState { vodStates[playlist.id] ?? .idle }

    func loadVod(_ playlist: Playlist) async {
        guard let creds = xtreamLogin(for: playlist) else {
            vodStates[playlist.id] = .unavailable
            return
        }
        let hadVod: Bool = { if case .loaded = vodState(of: playlist) { return true }; return false }()
        if !hadVod { vodStates[playlist.id] = .loading }
        do {
            let vod = try await loader.loadVod(server: creds.server, username: creds.username, password: creds.password)
            let built = await Self.background { VodIndex(vod) }
            vodStates[playlist.id] = .loaded(built)
            saveCache(playlist.id, "vod") { try LibraryCache.shared.saveVod(library: vod, path: $0) }
        } catch {
            if !hadVod { vodStates[playlist.id] = .failed(Self.message(for: error)) }
        }
    }

    /// A film's details. Kept on the phone too (for a week), so a page seen before opens at once,
    /// even after a relaunch; an old copy is still used when the provider doesn't answer.
    func movieInfo(_ movie: Movie, in playlist: Playlist) async throws -> MovieInfo {
        if let cached = movieInfoCache[movie.id] { return cached }
        let path = Self.detailsPath(playlist.id, "m", movie.id)
        let saved = await Self.background { LibraryCache.shared.loadMovieInfo(path: path) }
        if let saved, !Self.isOld(path, hours: 24 * 7) {
            movieInfoCache[movie.id] = saved
            return saved
        }
        guard let creds = xtreamLogin(for: playlist) else { throw PlaylistError(message: "No login.") }
        do {
            let info = try await loader.movieInfo(server: creds.server, username: creds.username, password: creds.password, movieId: movie.id)
            movieInfoCache[movie.id] = info
            Task.detached(priority: .utility) { try? LibraryCache.shared.saveMovieInfo(info: info, path: path) }
            return info
        } catch {
            if let saved { return saved }
            throw PlaylistError(message: Self.message(for: error))
        }
    }

    /// A series' seasons and episodes. Kept on the phone for 6 hours (new episodes appear), and
    /// an old copy is shown at once while a fresh one loads (`refreshed` gets it).
    func seriesInfo(_ series: Series, in playlist: Playlist, refreshed: ((SeriesInfo) -> Void)? = nil) async throws -> SeriesInfo {
        if let cached = seriesInfoCache[series.id] { return cached }
        let path = Self.detailsPath(playlist.id, "s", series.id)
        let saved = await Self.background { LibraryCache.shared.loadSeriesInfo(path: path) }
        guard let creds = xtreamLogin(for: playlist) else {
            if let saved { return saved }
            throw PlaylistError(message: "No login.")
        }
        let fetch: () async throws -> SeriesInfo = { [loader] in
            try await loader.seriesInfo(server: creds.server, username: creds.username, password: creds.password, seriesId: series.id)
        }
        if let saved {
            seriesInfoCache[series.id] = saved
            if Self.isOld(path, hours: 6) {
                Task {
                    guard let fresh = try? await fetch() else { return }
                    seriesInfoCache[series.id] = fresh
                    Task.detached(priority: .utility) { try? LibraryCache.shared.saveSeriesInfo(info: fresh, path: path) }
                    refreshed?(fresh)
                }
            }
            return saved
        }
        do {
            let info = try await fetch()
            seriesInfoCache[series.id] = info
            Task.detached(priority: .utility) { try? LibraryCache.shared.saveSeriesInfo(info: info, path: path) }
            return info
        } catch {
            throw PlaylistError(message: Self.message(for: error))
        }
    }

    /// `Library/Caches/Lumen/details/<playlist>-m-<id>.json` (films) or `-s-` (series).
    nonisolated static func detailsPath(_ id: UUID, _ kind: String, _ itemId: String) -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen/details", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = itemId.filter { $0.isLetter || $0.isNumber }
        return dir.appendingPathComponent("\(id.uuidString)-\(kind)-\(safe).json").path
    }

    nonisolated static func isOld(_ path: String, hours: Double) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return true }
        return Date.now.timeIntervalSince(modified) > hours * 3600
    }

    private struct XtreamCredentials {
        let server: String
        let username: String
        let password: String
    }

    private func xtreamLogin(for playlist: Playlist) -> XtreamCredentials? {
        guard playlist.kind == .xtream, let login = login(for: playlist),
              let server = login.server, let username = login.username, let password = login.password else { return nil }
        return XtreamCredentials(server: server, username: username, password: password)
    }

    // MARK: Playlist settings

    func rename(_ playlist: Playlist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = trimmed
        save()
    }

    /// Server and username of an Xtream playlist, for the Settings form (never the password).
    func xtreamDetails(_ playlist: Playlist) -> (server: String, username: String)? {
        guard let login = login(for: playlist), let server = login.server, let username = login.username else { return nil }
        return (server, username)
    }

    func guideUrl(_ playlist: Playlist) -> String? { login(for: playlist)?.guideUrl }

    /// Saves a typed guide link (blank = the provider's own) and reloads the guide.
    func setGuideUrl(_ playlist: Playlist, _ url: String) async {
        guard var login = login(for: playlist) else { return }
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        login.guideUrl = trimmed.isEmpty ? nil : trimmed
        store(login, for: playlist)
        guideStates[playlist.id] = nil
        await loadGuide(playlist)
    }

    /// New Xtream details: checked by loading the channels first, and only saved if that works
    /// (like `changeConnection` on the TV). A blank password keeps the old one.
    func changeXtream(_ playlist: Playlist, server: String, username: String, password: String) async throws {
        guard let old = login(for: playlist) else { throw PlaylistError(message: "This playlist's login is missing.") }
        var login = PlaylistLogin(server: server, username: username, password: password.isEmpty ? old.password : password)
        login.guideUrl = old.guideUrl
        try await change(playlist, to: login, kind: .xtream)
    }

    /// A new M3U link (a get.php link is stored as Xtream, as when adding).
    func changeM3u(_ playlist: Playlist, link: String) async throws {
        let old = login(for: playlist)
        var login: PlaylistLogin
        var kind = Playlist.Kind.m3u
        if let parts = loader.xtreamLogin(link: link) {
            login = PlaylistLogin(server: parts.server, username: parts.username, password: parts.password)
            kind = .xtream
        } else {
            login = PlaylistLogin(link: link)
        }
        login.guideUrl = old?.guideUrl
        try await change(playlist, to: login, kind: kind)
    }

    private func change(_ playlist: Playlist, to login: PlaylistLogin, kind: Playlist.Kind) async throws {
        let library: LiveLibrary
        do {
            library = try await load(login)
        } catch {
            throw PlaylistError(message: Self.message(for: error))
        }
        let built = await Self.background { LoadedLibrary(library) }
        store(login, for: playlist)
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index].kind = kind
            playlists[index].host = Self.host(of: login)
            save()
        }
        states[playlist.id] = .loaded(built)
        saveCache(playlist.id, "live") { try LibraryCache.shared.saveLive(library: library, path: $0) }
        guideStates[playlist.id] = nil
        vodStates[playlist.id] = nil
        let updated = playlists.first { $0.id == playlist.id } ?? playlist
        Task { await loadGuide(updated) }
        Task { await loadVod(updated) }
    }

    private func store(_ login: PlaylistLogin, for playlist: Playlist) {
        if let data = try? JSONEncoder().encode(login) {
            Keychain.save(data, for: playlist.id.uuidString)
        }
    }

    private static func host(of login: PlaylistLogin) -> String {
        URL(string: login.server.map { $0.contains("://") ? $0 : "http://\($0)" } ?? login.link ?? "")?.host() ?? "Playlist"
    }

    // MARK: Categories (hide and rename)

    static func liveCategoryKey(_ name: String) -> String { "l:\(name)" }
    static func movieCategoryKey(_ id: String) -> String { "m:\(id)" }
    static func seriesCategoryKey(_ id: String) -> String { "s:\(id)" }

    func isHidden(_ key: String, in playlist: Playlist) -> Bool {
        hiddenCategories[playlist.id]?.contains(key) == true
    }

    func setHidden(_ keys: [String], _ hidden: Bool, in playlist: Playlist) {
        var set = hiddenCategories[playlist.id] ?? []
        if hidden { set.formUnion(keys) } else { set.subtract(keys) }
        hiddenCategories[playlist.id] = set
        saveCategorySettings()
    }

    /// The user's name for a category, else [fallback] (the tidied provider name).
    func label(_ key: String, fallback: String, in playlist: Playlist) -> String {
        categoryLabels[playlist.id]?[key] ?? fallback
    }

    /// Blank, or the same as the provider's, removes the rename.
    func rename(_ key: String, to name: String, fallback: String, in playlist: Playlist) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var labels = categoryLabels[playlist.id] ?? [:]
        labels[key] = (trimmed.isEmpty || trimmed == fallback) ? nil : trimmed
        categoryLabels[playlist.id] = labels
        saveCategorySettings()
    }

    /// Live categories to show (hidden ones left out), with the user's names.
    func visibleLiveCategories(_ loaded: LoadedLibrary, in playlist: Playlist) -> [(key: String, title: String)] {
        var items = loaded.categories.compactMap { c -> (key: String, title: String)? in
            let key = Self.liveCategoryKey(c.name)
            return isHidden(key, in: playlist) ? nil : (c.name, label(key, fallback: c.title, in: playlist))
        }
        if loaded.channelsByCategory[LoadedLibrary.otherKey] != nil {
            items.append((LoadedLibrary.otherKey, "Other channels"))
        }
        return items
    }

    func liveCategoryTitle(_ name: String?, in playlist: Playlist?, loaded: LoadedLibrary) -> String? {
        guard let name else { return nil }
        let fallback = loaded.categories.first { $0.name == name }?.title ?? name
        guard let playlist else { return fallback }
        return label(Self.liveCategoryKey(name), fallback: fallback, in: playlist)
    }

    func vodCategoryKey(_ category: VodCategory, _ kind: VodKind) -> String {
        kind == .movies ? Self.movieCategoryKey(category.id) : Self.seriesCategoryKey(category.id)
    }

    func vodCategoryTitle(_ category: VodCategory, _ kind: VodKind, in playlist: Playlist) -> String {
        label(vodCategoryKey(category, kind), fallback: category.title, in: playlist)
    }

    private func saveCategorySettings() {
        if let data = try? JSONEncoder().encode(hiddenCategories) { CloudSync.shared.set(data, forKey: hiddenKey) }
        if let data = try? JSONEncoder().encode(categoryLabels) { CloudSync.shared.set(data, forKey: labelsKey) }
    }

    // MARK: My List

    func isInMyList(_ kind: MyListItem.Kind, id: String, in playlist: Playlist) -> Bool {
        myList[playlist.id]?.contains { $0.kind == kind && $0.id == id } == true
    }

    func toggleMyList(_ movie: Movie, in playlist: Playlist) {
        toggleMyList(MyListItem(kind: .movie, id: movie.id, title: movie.title, posterUrl: movie.posterUrl, added: .now), in: playlist)
    }

    func toggleMyList(_ series: Series, in playlist: Playlist) {
        toggleMyList(MyListItem(kind: .series, id: series.id, title: series.title, posterUrl: series.posterUrl, added: .now), in: playlist)
    }

    func toggleMyList(_ item: MyListItem, in playlist: Playlist) {
        Haptics.tap()
        var items = myList[playlist.id] ?? []
        if let index = items.firstIndex(where: { $0.kind == item.kind && $0.id == item.id }) {
            items.remove(at: index)
        } else {
            items.insert(item, at: 0)
        }
        myList[playlist.id] = items
        saveMyList()
    }

    func myList(in playlist: Playlist) -> [MyListItem] { myList[playlist.id] ?? [] }

    private func saveMyList() {
        if let data = try? JSONEncoder().encode(myList) {
            CloudSync.shared.set(data, forKey: myListKey)
        }
    }

    // MARK: Watch progress

    func progress(_ key: String, in playlist: Playlist) -> WatchProgress? { progress[playlist.id]?[key] }

    /// Saves where playback is. Like the TV: under 30 s isn't worth keeping. `quietly`: the
    /// periodic save during playback, kept from the pages until the next normal save.
    func saveProgress(_ item: WatchProgress, in playlist: Playlist, quietly: Bool = false) {
        guard item.position >= 30 || progress[playlist.id]?[item.key] != nil
            || unpublishedProgress[playlist.id]?[item.key] != nil else { return }
        if quietly {
            unpublishedProgress[playlist.id, default: [:]][item.key] = item
        } else {
            unpublishedProgress[playlist.id]?[item.key] = nil
            progress[playlist.id, default: [:]][item.key] = item
        }
        saveProgress()
    }

    func removeProgress(_ key: String, in playlist: Playlist) {
        unpublishedProgress[playlist.id]?[key] = nil
        progress[playlist.id]?[key] = nil
        saveProgress()
    }

    /// Unfinished films (or series, one entry each), most recent first.
    func continueWatching(_ kind: WatchProgress.Kind, in playlist: Playlist) -> [WatchProgress] {
        let items = (progress[playlist.id] ?? [:]).values.filter { $0.kind == kind && !$0.finished }
        var seenSeries = Set<String>()
        return items.sorted { $0.updated > $1.updated }.filter { item in
            guard let series = item.seriesId else { return true }
            return seenSeries.insert(series).inserted
        }
    }

    private func saveProgress() {
        var all = progress
        for (id, items) in unpublishedProgress {
            all[id, default: [:]].merge(items) { _, newer in newer }
        }
        if let data = try? JSONEncoder().encode(all) {
            CloudSync.shared.set(data, forKey: progressKey)
        }
    }

    private func load(_ login: PlaylistLogin) async throws -> LiveLibrary {
        if let link = login.link {
            return try await loader.loadM3u(link: link)
        }
        return try await loader.loadXtream(
            server: login.server ?? "", username: login.username ?? "", password: login.password ?? ""
        )
    }

    private func login(for playlist: Playlist) -> PlaylistLogin? {
        Keychain.load(playlist.id.uuidString).flatMap { try? JSONDecoder().decode(PlaylistLogin.self, from: $0) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            CloudSync.shared.set(data, forKey: defaultsKey)
        }
    }

    /// A Kotlin exception comes through as an NSError carrying the original exception;
    /// its message is already worded for the user (`LoadException` in the shared code).
    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if let kotlin = nsError.userInfo["KotlinException"] as? KotlinThrowable, let message = kotlin.message {
            return message
        }
        return error.localizedDescription
    }
}

enum GuideState {
    case idle, loading, loaded(Guide), failed(String)
    /// An M3U playlist without a guide link.
    case unavailable
}

extension Guide {
    func nowNext(_ channel: LiveChannel, at date: Date = .now) -> NowNext? {
        nowNext(tvgId: channel.tvgId, now: Int64(date.timeIntervalSince1970))
    }
}

extension Programme {
    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var stopDate: Date { Date(timeIntervalSince1970: TimeInterval(stop)) }

    func progress(at date: Date) -> Double { progress(now: Int64(date.timeIntervalSince1970)) }

    /// "7:30 – 8:00 PM".
    var timeRange: String {
        "\(startDate.formatted(date: .omitted, time: .shortened)) – \(stopDate.formatted(date: .omitted, time: .shortened))"
    }

    /// "8 min left", "starts in 22 min", "ended".
    func relative(to date: Date) -> String {
        let now = Int64(date.timeIntervalSince1970)
        if now < start {
            let minutes = Int((start - now + 59) / 60)
            return minutes >= 60 ? "starts at \(startDate.formatted(date: .omitted, time: .shortened))" : "starts in \(minutes) min"
        }
        if now < stop { return "\(Int((stop - now + 59) / 60)) min left" }
        return "ended"
    }
}

struct PlaylistError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
