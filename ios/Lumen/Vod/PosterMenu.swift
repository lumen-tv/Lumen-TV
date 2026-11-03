import Shared
import SwiftUI

// Long-press on a poster (Hayat 2026-11-03): a preview card with the picture, facts and
// description, and Play / My List under it, without opening the page.

extension EnvironmentValues {
    /// Plays a film or episode from anywhere in a stack of posters (the long-press menu's Play).
    /// Set by `vodDestinations`, which presents the player.
    @Entry var playVod: ((VodPlayback) -> Void)? = nil
}

extension View {
    /// Hold a film's poster: preview + Play/Resume + My List. Nothing when there's no playlist.
    @ViewBuilder
    func posterMenu(movie: Movie, playlist: Playlist?) -> some View {
        if let playlist { modifier(MoviePosterMenu(movie: movie, playlist: playlist)) } else { self }
    }

    @ViewBuilder
    func posterMenu(series: Series, playlist: Playlist?) -> some View {
        if let playlist { modifier(SeriesPosterMenu(series: series, playlist: playlist)) } else { self }
    }
}

private struct MoviePosterMenu: ViewModifier {
    let movie: Movie
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.playVod) private var playVod

    func body(content: Content) -> some View {
        content.contextMenu {
            if let playVod {
                let saved = store.progress(WatchProgress.movieKey(movie.id), in: playlist)
                let resume = saved.flatMap { $0.finished ? nil : $0.position }
                Button(resume.map { "Resume from \(formatTime($0))" } ?? "Play", systemImage: "play.fill") {
                    Task {
                        let info = try? await store.movieInfo(movie, in: playlist)
                        playVod(moviePlayback(movie, info: info, from: resume ?? 0))
                    }
                }
            }
            let inList = store.isInMyList(.movie, id: movie.id, in: playlist)
            Button(inList ? "Remove from My List" : "Add to My List", systemImage: inList ? "heart.slash" : "heart") {
                store.toggleMyList(movie, in: playlist)
                Haptics.tap()
            }
        } preview: {
            MoviePreview(movie: movie, playlist: playlist).environment(store)
        }
    }
}

private struct SeriesPosterMenu: ViewModifier {
    let series: Series
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.playVod) private var playVod

    func body(content: Content) -> some View {
        content.contextMenu {
            if let playVod {
                Button("Play", systemImage: "play.fill") {
                    Task {
                        if let next = await nextUpPlayback(series, store: store, playlist: playlist) { playVod(next) }
                    }
                }
            }
            let inList = store.isInMyList(.series, id: series.id, in: playlist)
            Button(inList ? "Remove from My List" : "Add to My List", systemImage: inList ? "heart.slash" : "heart") {
                store.toggleMyList(series, in: playlist)
                Haptics.tap()
            }
        } preview: {
            PreviewCard(picture: series.backdropUrl ?? series.posterUrl, title: series.title,
                        facts: [series.year.map { "\($0.intValue)" }, series.genre].compactMap { $0 }.joined(separator: " · "),
                        plot: series.plot)
        }
    }
}

/// A film's preview: its details load while you hold (the list has no description or backdrop).
private struct MoviePreview: View {
    let movie: Movie
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @State private var info: MovieInfo?

    var body: some View {
        PreviewCard(picture: info?.backdropUrl ?? movie.posterUrl, title: movie.title, facts: facts, plot: info?.plot)
            .task { info = try? await store.movieInfo(movie, in: playlist) }
    }

    private var facts: String {
        var parts: [String] = []
        if let year = movie.year { parts.append("\(year.intValue)") }
        if let genre = info?.genre { parts.append(genre) }
        if let secs = info?.durationSecs?.doubleValue { parts.append(formatDuration(secs)) }
        return parts.joined(separator: " · ")
    }
}

/// The card: a wide picture, the title, a facts line and three lines of description.
private struct PreviewCard: View {
    let picture: String?
    let title: String
    let facts: String
    let plot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterImage(url: picture, title: title)
                .frame(width: 340, height: 191)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(LumenFont.inter(20, .semibold)).foregroundStyle(LumenColors.textPrimary).lineLimit(2)
                if !facts.isEmpty {
                    Text(facts).font(LumenFont.caption).foregroundStyle(LumenColors.textSecondary).lineLimit(1)
                }
                if let plot {
                    Text(plot).font(LumenFont.inter(14)).foregroundStyle(LumenColors.textPrimary.opacity(0.85)).lineLimit(3)
                }
            }
            .padding(16)
            .frame(width: 340, alignment: .leading)
        }
        .background(LumenColors.background)
    }
}

/// A Continue watching entry as something to play: a film where it stopped; an episode where it
/// stopped, or the next one when that one was finished. Nil when it's no longer in the playlist.
@MainActor
func resumePlayback(_ item: WatchProgress, store: PlaylistStore, playlist: Playlist) async -> VodPlayback? {
    guard case .loaded(let index) = store.vodState(of: playlist) else { return nil }
    if let id = item.movieId, let movie = index.movieById[id] {
        let info = try? await store.movieInfo(movie, in: playlist)
        return moviePlayback(movie, info: info, from: item.finished ? 0 : item.position)
    }
    guard let seriesId = item.seriesId, let series = index.seriesById[seriesId],
          let info = try? await store.seriesInfo(series, in: playlist) else { return nil }
    let episodes = info.episodes
    let episodeId = String(item.key.dropFirst(2)) // "e:<id>"
    guard let at = episodes.firstIndex(where: { $0.id == episodeId }) else { return nil }
    let moveOn = item.finished && at + 1 < episodes.count
    let episode = moveOn ? episodes[at + 1] : episodes[at]
    return episodePlayback(series, episode, from: item.finished ? 0 : item.position, episodes: episodes, tmdbId: info.tmdbId)
}
