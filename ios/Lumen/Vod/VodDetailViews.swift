import Shared
import SwiftUI

/// What the VOD player gets: the stream and where to save progress.
struct VodPlayback: Identifiable {
    let id = UUID()
    let streamUrl: String
    let title: String
    let startAt: Double
    /// Template for the saved progress (position and duration are filled in while playing).
    let progress: WatchProgress
    /// For a series: the episodes after this one, for "Next episode".
    var upNext: [VodPlayback] = []
    /// For a series episode: what to look up for Skip intro.
    var skipRef: SkipRef? = nil
}

func moviePlayback(_ movie: Movie, info: MovieInfo?, from start: Double) -> VodPlayback {
    VodPlayback(
        streamUrl: movie.streamUrl,
        title: movie.title,
        startAt: start,
        progress: WatchProgress(
            key: WatchProgress.movieKey(movie.id), kind: .movie, seriesId: nil, movieId: movie.id, title: movie.title,
            posterUrl: movie.posterUrl, position: start,
            duration: info?.durationSecs?.doubleValue ?? 0, updated: .now
        )
    )
}

/// An episode's playback, with the next 20 episodes queued for "Next episode".
func episodePlayback(_ series: Series, _ episode: Episode, from start: Double, episodes: [Episode]?, tmdbId: String? = nil) -> VodPlayback {
    let title = "\(series.title) · S\(episode.season) E\(episode.episode)"
    var playback = VodPlayback(
        streamUrl: episode.streamUrl,
        title: episode.title.map { "\(title) · \($0)" } ?? title,
        startAt: start,
        progress: WatchProgress(
            key: WatchProgress.episodeKey(episode.id), kind: .series, seriesId: series.id, movieId: nil,
            title: title, posterUrl: series.posterUrl, position: start,
            duration: episode.durationSecs?.doubleValue ?? 0, updated: .now
        )
    )
    playback.skipRef = SkipRef(
        seriesTitle: series.title, year: series.year?.intValue, tmdbId: tmdbId,
        season: Int(episode.season), episode: Int(episode.episode), durationSecs: episode.durationSecs?.intValue
    )
    if let episodes, let index = episodes.firstIndex(of: episode) {
        playback.upNext = episodes.dropFirst(index + 1).prefix(20).map { episodePlayback(series, $0, from: 0, episodes: nil, tmdbId: tmdbId) }
    }
    return playback
}

/// Which episode Play starts, like `NextUp.pick` on the TV: the one you were last watching if
/// unfinished, else the one after it, else the first.
enum NextUp {
    struct Pick {
        let episode: Episode
        let resume: Double
        let label: String
    }

    static func pick(_ episodes: [Episode], progress: (Episode) -> WatchProgress?) -> Pick? {
        guard let first = episodes.first else { return nil }
        func resume(_ e: Episode) -> Double {
            guard let saved = progress(e), !saved.finished else { return 0 }
            return saved.position
        }
        let watched = episodes.compactMap { e in progress(e).map { (e, $0) } }
        guard let latest = watched.max(by: { $0.1.updated < $1.1.updated }) else {
            return Pick(episode: first, resume: 0, label: "Play S\(first.season) · E\(first.episode)")
        }
        let (last, saved) = latest
        if !saved.finished {
            return Pick(episode: last, resume: saved.position, label: "Resume S\(last.season) · E\(last.episode)")
        }
        let index = episodes.firstIndex(of: last) ?? 0
        let next = index + 1 < episodes.count ? episodes[index + 1] : first
        return Pick(episode: next, resume: resume(next), label: "Play S\(next.season) · E\(next.episode)")
    }
}

/// Play on a series from outside its page (the Series tab's hero): loads the episodes first.
@MainActor
func nextUpPlayback(_ series: Series, store: PlaylistStore, playlist: Playlist) async -> VodPlayback? {
    guard let info = try? await store.seriesInfo(series, in: playlist),
          let pick = NextUp.pick(info.episodes, progress: { store.progress(WatchProgress.episodeKey($0.id), in: playlist) })
    else { return nil }
    return episodePlayback(series, pick.episode, from: pick.resume, episodes: info.episodes, tmdbId: info.tmdbId)
}

/// The film or series picture behind the whole page, as on the TV: it stays put while the text
/// scrolls over it, and fades out into the page through a mask, so it meets the page's own colour
/// without a band (a fade to a fixed colour left hard edges: Hayat's iPad screenshot 2026-10-31).
/// iPad: the full screen, under the top pill too, darker on the left behind the text.
/// iPhone: the top part of the screen.
struct PageBackdrop: View {
    let url: String?
    @Environment(\.lumenWide) private var wide
    @Environment(\.pageTopInset) private var top

    var body: some View {
        GeometryReader { geo in
            let height = wide ? geo.size.height : min(geo.size.height * 0.62, geo.size.width * 1.15)
            // The picture goes in an overlay of a fixed-size frame: a scaledToFill image laid out
            // directly would make the whole page as wide as the picture (SwiftUI sizes a ZStack to
            // its biggest child, unlike a UIImageView with clipsToBounds).
            Color.clear
                .frame(width: geo.size.width, height: height)
                .overlay {
                    if let url, let parsed = URL(string: url) {
                        AsyncImage(url: parsed) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill().transition(.opacity)
                            }
                        }
                    }
                }
                .overlay {
                    if wide {
                        LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5))
                    }
                }
                .overlay {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.45), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: wide ? 0.6 : 0.5), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        // iPad: reach up behind the top pill and clock (RootView draws the pill above the page).
        .padding(.top, wide ? -top : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The empty space at the top of a film or series page, where the picture shows through.
private struct BackdropSpace: View {
    @Environment(\.lumenWide) private var wide

    var body: some View {
        Color.clear.containerRelativeFrame(.vertical) { height, _ in height * (wide ? 0.4 : 0.38) }
    }
}

/// Big numbers with a small label under each ("7.5 / Rating", "PG / Age rating"), as plain text:
/// the App Store build can't show other companies' logos (the TV's tomato and IMDb box).
struct RatingsRow: View {
    let items: [(value: String, label: String)]

    var body: some View {
        if !items.isEmpty {
            HStack(alignment: .top, spacing: 28) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(items[i].value).font(LumenFont.inter(30, .semibold)).foregroundStyle(LumenColors.textPrimary)
                        Text(items[i].label).font(LumenFont.caption).foregroundStyle(LumenColors.textSecondary)
                    }
                }
            }
        }
    }
}

/// The text block over the lower part of the backdrop.
private struct DetailBody<Content: View>: View {
    @Environment(\.lumenWide) private var wide
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: wide ? 760 : .infinity, alignment: .leading)
            .lumenGutter(wide)
    }
}

private struct DetailTitle: View {
    let title: String
    let quality: String?
    let facts: String
    @Environment(\.lumenWide) private var wide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(LumenFont.inter(wide ? 52 : 36, .semibold))
                    .foregroundStyle(LumenColors.textPrimary)
                    .minimumScaleFactor(0.6)
                if let quality { QualityTag(text: quality) }
            }
            if !facts.isEmpty {
                Text(facts).font(LumenFont.inter(wide ? 18 : 15)).foregroundStyle(LumenColors.textSecondary)
            }
        }
    }
}

extension View {
    /// Pushed pages show the system back button over the backdrop, with no bar behind it.
    func detailPageChrome() -> some View {
        self.ignoresSafeArea(edges: .top)
            .background(AmbientBackground())
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct MovieDetailView: View {
    let movie: Movie
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @State private var info: MovieInfo?
    @State private var omdb: OmdbRatings?
    @State private var playback: VodPlayback?

    private var key: String { WatchProgress.movieKey(movie.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackdropSpace()
                DetailBody {
                    DetailTitle(title: movie.title, quality: movie.quality, facts: facts)
                    buttons
                    RatingsRow(items: ratings).padding(.top, 4)
                    if let plot = info?.plot {
                        Text(plot).font(LumenFont.inter(wide ? 18 : 16)).foregroundStyle(LumenColors.textPrimary.opacity(0.9))
                            .lineSpacing(3)
                    }
                    if let cast = info?.cast {
                        Text("Cast: \(cast)").font(LumenFont.inter(14)).foregroundStyle(LumenColors.textSecondary)
                    }
                    if let director = info?.director {
                        Text("Director: \(director)").font(LumenFont.inter(14)).foregroundStyle(LumenColors.textSecondary)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background { PageBackdrop(url: info?.backdropUrl ?? movie.posterUrl) }
        .detailPageChrome()
        .task { info = try? await store.movieInfo(movie, in: playlist) }
        .task { omdb = await Omdb.shared.ratings(title: movie.title, year: movie.year?.intValue, series: false) }
        .fullScreenCover(item: $playback) { VodPlayerView(playback: $0, playlist: playlist) }
    }

    private var facts: String {
        var parts: [String] = []
        if let year = movie.year { parts.append("\(year.intValue)") }
        if let genre = info?.genre { parts.append(genre) }
        if let secs = info?.durationSecs?.doubleValue { parts.append(formatDuration(secs)) }
        return parts.joined(separator: " · ")
    }

    private var ratings: [(value: String, label: String)] {
        OmdbRatings.items(omdb, provider: movie.rating?.doubleValue, age: info?.ageRating)
    }

    /// iPhone: Resume and the heart on one line, Start over full width under them.
    /// iPad: all on one line.
    @ViewBuilder
    private var buttons: some View {
        let saved = store.progress(key, in: playlist)
        let resume: Double? = saved.flatMap { $0.finished ? nil : $0.position }
        let heart = MyListButton(inList: store.isInMyList(.movie, id: movie.id, in: playlist)) {
            store.toggleMyList(movie, in: playlist)
        }
        let playButton = Button { play(from: resume ?? 0) } label: {
            Label(resume.map { "Resume from \(formatTime($0))" } ?? "Play", systemImage: "play.fill")
                .frame(maxWidth: wide ? nil : .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        let startOver = Button { play(from: 0) } label: {
            Label("Start over", systemImage: "arrow.counterclockwise").frame(maxWidth: wide ? nil : .infinity)
        }
        .buttonStyle(GlassButtonStyle())

        if wide {
            HStack(spacing: 12) {
                playButton
                if resume != nil { startOver }
                heart
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) { playButton; heart }
                if resume != nil { startOver }
            }
        }
    }

    private func play(from start: Double) {
        playback = moviePlayback(movie, info: info, from: start)
    }
}

struct SeriesDetailView: View {
    let series: Series
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @State private var info: SeriesInfo?
    @State private var error: String?
    @State private var season: Int32 = 1
    @State private var omdb: OmdbRatings?
    @State private var playback: VodPlayback?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackdropSpace()
                DetailBody {
                    DetailTitle(title: series.title, quality: nil, facts: facts)
                    HStack(spacing: 12) {
                        if let pick = nextUp {
                            Button { play(pick.episode, from: pick.resume) } label: {
                                Label(pick.label, systemImage: "play.fill").frame(maxWidth: wide ? nil : .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        MyListButton(inList: store.isInMyList(.series, id: series.id, in: playlist)) {
                            store.toggleMyList(series, in: playlist)
                        }
                    }
                    RatingsRow(items: OmdbRatings.items(omdb, provider: series.rating?.doubleValue, age: nil)).padding(.top, 4)
                    if let plot = series.plot {
                        Text(plot).font(LumenFont.inter(wide ? 18 : 16)).foregroundStyle(LumenColors.textPrimary.opacity(0.9))
                            .lineSpacing(3)
                    }
                    if let cast = info?.cast {
                        Text("Cast: \(cast)").font(LumenFont.inter(14)).foregroundStyle(LumenColors.textSecondary)
                    }
                    episodes.padding(.top, 8)
                }
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background { PageBackdrop(url: series.backdropUrl ?? series.posterUrl) }
        .detailPageChrome()
        .task { omdb = await Omdb.shared.ratings(title: series.title, year: series.year?.intValue, series: true) }
        .task {
            do {
                let loaded = try await store.seriesInfo(series, in: playlist)
                info = loaded
                season = nextUp.map { $0.episode.season } ?? loaded.seasons.first?.int32Value ?? 1
            } catch {
                self.error = error.localizedDescription
            }
        }
        .fullScreenCover(item: $playback) { VodPlayerView(playback: $0, playlist: playlist) }
    }

    private var facts: String {
        var parts: [String] = []
        if let year = series.year { parts.append("\(year.intValue)") }
        if let genre = series.genre { parts.append(genre) }
        if let count = info?.seasons.count, count > 0 { parts.append(count == 1 ? "1 season" : "\(count) seasons") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var episodes: some View {
        if let error {
            Text(error).font(LumenFont.body).foregroundStyle(LumenColors.textSecondary)
        } else if let info {
            if info.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(info.seasons.map(\.int32Value), id: \.self) { number in
                            ChipButton(title: "Season \(number)", selected: number == season, large: wide) { season = number }
                        }
                    }
                }
            }
            VStack(spacing: 6) {
                ForEach(info.episodes.filter { $0.season == season }, id: \.id) { episode in
                    Button { play(episode, from: resumePosition(episode)) } label: {
                        EpisodeRow(episode: episode, progress: progress(episode))
                    }
                    .buttonStyle(ChannelRowStyle())
                    .padding(.horizontal, -12)
                }
            }
        } else {
            ProgressView().tint(.white).frame(maxWidth: .infinity)
        }
    }

    private func progress(_ episode: Episode) -> WatchProgress? {
        store.progress(WatchProgress.episodeKey(episode.id), in: playlist)
    }

    private func resumePosition(_ episode: Episode) -> Double {
        guard let saved = progress(episode), !saved.finished else { return 0 }
        return saved.position
    }

    private var nextUp: NextUp.Pick? {
        info.flatMap { NextUp.pick($0.episodes, progress: progress) }
    }

    private func play(_ episode: Episode, from start: Double) {
        playback = episodePlayback(series, episode, from: start, episodes: info?.episodes, tmdbId: info?.tmdbId)
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let progress: WatchProgress?
    @Environment(\.lumenWide) private var wide

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottom) {
                PosterImage(url: episode.imageUrl, title: "E\(episode.episode)")
                if let progress {
                    ProgressLine(fraction: progress.fraction, height: 3, track: .white.opacity(0.3)).padding(6)
                }
            }
            .frame(width: wide ? 200 : 140, height: wide ? 112 : 79)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episode). \(episode.title ?? "Episode \(episode.episode)")")
                    .font(LumenFont.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let secs = episode.durationSecs?.doubleValue {
                    Text(formatDuration(secs)).font(LumenFont.caption).foregroundStyle(.secondary)
                }
                if let plot = episode.plot {
                    Text(plot).font(LumenFont.caption).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// "1 h 52 min" / "48 min".
func formatDuration(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
}
