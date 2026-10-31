import Shared
import SwiftUI

/// The Live TV tab's first screen, as on the TV: the chosen favourite as a big hero over a wash
/// of its colour, then the favourites as 16:9 tiles (2 across on iPhone, 4 on iPad).
/// Tap a tile to watch (zapping through favourites); hold it to move or remove it.
/// "All channels" opens every category.
struct HomeView: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @State private var playing: PlayerRoute?
    /// The favourite shown in the hero: the last one watched (the TV uses the focused card;
    /// a touch screen has no focus, so it follows what you tap).
    @AppStorage("homeHeroKey") private var heroKey = ""
    @State private var editingFavourites = false

    var body: some View {
        NavigationStack {
            Group {
                if let playlist = store.selected {
                    content(playlist)
                } else {
                    EmptyTab(title: "Live TV", message: "Add your playlist or Xtream login to see your channels.")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .allChannels: LiveChannelsView()
                case .guide: GuideView()
                }
            }
        }
        .playerCover($playing)
    }

    @ViewBuilder
    private func content(_ playlist: Playlist) -> some View {
        switch store.state(of: playlist) {
        case .idle, .loading:
            StatusMessage(text: "Loading channels…", loading: true)
        case .failed(let message):
            StatusMessage(text: message) { Task { await store.refresh(playlist) } }
        case .loaded(let loaded):
            let favourites = store.favourites(in: playlist)
            let hero = favourites.first { $0.key == heroKey } ?? favourites.first
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !wide { phoneHeader }
                    if let hero {
                        heroView(hero, loaded: loaded, favourites: favourites)
                        favouritesGrid(favourites, hero: hero, playlist: playlist)
                    } else {
                        noFavourites
                    }
                }
                // Full width even when the content is narrow (the empty state): the ScrollView
                // took its content's width, which left black bars on the iPad.
                .frame(maxWidth: .infinity, alignment: .leading)
                .lumenGutter(wide)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refreshEverything(playlist) }
            .background(AmbientBackground(tint: hero.map { NameTile.colour(for: $0.title) } ?? LumenColors.ambientCool))
            .sheet(isPresented: $editingFavourites) { FavouritesEditView(playlist: playlist) }
        }
    }

    /// iPhone only (the iPad has the clock in its top bar): today's date.
    private var phoneHeader: some View {
        Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
            .font(LumenFont.body)
            .foregroundStyle(LumenColors.textSecondary)
            .padding(.top, 8)
    }

    private func heroView(_ channel: LiveChannel, loaded: LoadedLibrary, favourites: [LiveChannel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(channel.title)
                    .font(LumenFont.inter(wide ? 56 : 38, .semibold))
                    .foregroundStyle(LumenColors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let quality = channel.quality { QualityTag(text: quality) }
            }
            .contentTransition(.opacity)
            // Redraws on the minute so the progress line moves.
            TimelineView(.everyMinute) { context in
                if let nowNext = store.guide(for: store.selected)?.nowNext(channel, at: context.date) {
                    HeroGuideLines(nowNext: nowNext, date: context.date, wide: wide)
                } else if let category = categoryTitle(channel, loaded) {
                    Text(category)
                        .font(LumenFont.inter(wide ? 20 : 17, .medium))
                        .foregroundStyle(LumenColors.textSecondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    play(channel, in: favourites)
                } label: {
                    Label("Watch", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                NavigationLink(value: HomeRoute.guide) {
                    Label("TV guide", systemImage: "calendar")
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.top, 10)
        }
        .padding(.top, wide ? 40 : 36)
        .padding(.bottom, wide ? 44 : 32)
        .animation(.easeOut(duration: 0.25), value: channel.key)
    }

    private func favouritesGrid(_ favourites: [LiveChannel], hero: LiveChannel, playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Favourites").font(LumenFont.title).foregroundStyle(LumenColors.textPrimary)
                if wide {
                    Text("Hold a favourite to move or remove it")
                        .font(LumenFont.caption).foregroundStyle(LumenColors.textSecondary)
                        .padding(.leading, 10)
                }
                Spacer()
                NavigationLink(value: HomeRoute.allChannels) {
                    HStack(spacing: 4) {
                        Text("All channels")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    }
                    .font(LumenFont.inter(15, .medium))
                    .foregroundStyle(LumenColors.textSecondary)
                }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: wide ? 24 : 14), count: wide ? 4 : 2),
                spacing: wide ? 24 : 14
            ) {
                ForEach(favourites, id: \.key) { channel in
                    Button {
                        play(channel, in: favourites)
                    } label: {
                        ChannelArt(logoUrl: channel.logoUrl, title: channel.title, cornerRadius: 16)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay(alignment: .bottom) { TileProgress(channel: channel) }
                            .overlay {
                                if channel.key == hero.key {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(.white, lineWidth: 3)
                                        .padding(-5)
                                }
                            }
                    }
                    .buttonStyle(TileButtonStyle())
                    .contextMenu {
                        Button("Watch", systemImage: "play.fill") { play(channel, in: favourites) }
                        Button("Move…", systemImage: "arrow.up.arrow.down") { editingFavourites = true }
                        Button("Remove from favourites", systemImage: "star.slash", role: .destructive) {
                            store.toggleFavourite(channel, in: playlist)
                        }
                    }
                    .accessibilityLabel(channel.title)
                }
            }
            .padding(5) // room for the outline round the hero's tile
            .padding(.horizontal, -5)
            if !wide {
                Text("Hold a favourite to move or remove it")
                    .font(LumenFont.caption)
                    .foregroundStyle(LumenColors.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var noFavourites: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Favourites")
                .font(LumenFont.inter(wide ? 56 : 38, .semibold))
                .foregroundStyle(LumenColors.textPrimary)
            Text("Your favourite channels show here as big tiles. Open All channels and hold a channel to add it.")
                .font(LumenFont.body)
                .foregroundStyle(LumenColors.textSecondary)
                .frame(maxWidth: 460, alignment: .leading)
            NavigationLink(value: HomeRoute.allChannels) { Text("All channels") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
        }
        .padding(.top, wide ? 40 : 36)
    }

    private func play(_ channel: LiveChannel, in favourites: [LiveChannel]) {
        heroKey = channel.key
        playing = PlayerRoute(channels: favourites, index: favourites.firstIndex { $0.key == channel.key } ?? 0)
    }

    private func categoryTitle(_ channel: LiveChannel, _ loaded: LoadedLibrary) -> String? {
        guard let name = channel.categoryName else { return nil }
        return loaded.categories.first { $0.name == name }?.title
    }
}

enum HomeRoute: Hashable { case allChannels, guide }

/// Under the hero's channel name: "EastEnders  7:30 – 8:00 PM", a progress line, "Next  8:00 PM  Love Island".
struct HeroGuideLines: View {
    let nowNext: NowNext
    let date: Date
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let now = nowNext.now {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(now.title).font(LumenFont.inter(wide ? 22 : 18, .semibold)).foregroundStyle(LumenColors.textPrimary)
                        .lineLimit(1)
                    Text(now.timeRange).font(LumenFont.inter(wide ? 18 : 15)).foregroundStyle(LumenColors.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                ProgressLine(fraction: now.progress(at: date), height: 4)
                    .frame(width: wide ? 300 : 170)
            }
            if let next = nowNext.next {
                Text("Next  \(next.startDate.formatted(date: .omitted, time: .shortened))  \(next.title)")
                    .font(LumenFont.inter(wide ? 18 : 15))
                    .foregroundStyle(LumenColors.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The current programme's progress along the bottom of a favourite's tile.
struct TileProgress: View {
    let channel: LiveChannel
    @Environment(PlaylistStore.self) private var store

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let now = store.guide(for: store.selected)?.nowNext(channel, at: context.date)?.now {
                ProgressLine(fraction: now.progress(at: context.date), height: 3, track: .white.opacity(0.3))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }
}

/// Tiles shrink a little while pressed (the touch version of the TV's focus lift).
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}
