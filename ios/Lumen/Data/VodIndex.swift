import Foundation
import Shared

enum VodState {
    case idle, loading, loaded(VodIndex), failed(String)
    /// M3U playlists have no films or series.
    case unavailable
}

/// A playlist's films and series, grouped for the tabs.
struct VodIndex {
    let movieCategories: [VodCategory]
    let moviesByCategory: [String: [Movie]]
    let movieById: [String: Movie]
    let seriesCategories: [VodCategory]
    let seriesByCategory: [String: [Series]]
    let seriesById: [String: Series]

    init(_ vod: VodLibrary) {
        movieCategories = vod.movieCategories
        moviesByCategory = Dictionary(grouping: vod.movies, by: \.categoryId)
        movieById = Dictionary(vod.movies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        seriesCategories = vod.seriesCategories
        seriesByCategory = Dictionary(grouping: vod.series, by: \.categoryId)
        seriesById = Dictionary(vod.series.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Where you stopped in a film or episode. Holds no stream URL (those contain the password):
/// Continue watching opens the film or series page, which builds the URL again.
struct WatchProgress: Codable, Hashable {
    enum Kind: String, Codable { case movie, series }

    /// `m:<film id>` or `e:<episode id>`.
    let key: String
    let kind: Kind
    /// For an episode, its series.
    let seriesId: String?
    let movieId: String?
    /// "Lupin", or "Show · S1 E3".
    let title: String
    let posterUrl: String?
    var position: Double
    var duration: Double
    var updated: Date

    /// Like the TV: 95% counts as watched.
    var finished: Bool { duration > 0 && position >= duration * 0.95 }
    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }

    static func movieKey(_ id: String) -> String { "m:\(id)" }
    static func episodeKey(_ id: String) -> String { "e:\(id)" }
}

/// A film or series saved to My List. Like the TV's `my_list` table: keyed on the provider's id,
/// with the title and poster kept so the tab can show it before the films have loaded.
struct MyListItem: Codable, Hashable {
    enum Kind: String, Codable { case movie, series }
    let kind: Kind
    let id: String
    let title: String
    let posterUrl: String?
    let added: Date
}

/// "42:10" or "1:05:03".
func formatTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
