import Shared
import SwiftUI

/// "All channels": a search field, the playlist's categories as pills, and the chosen category's
/// channels as rows. Tap a row to watch (swiping up/down in the player zaps through the same
/// list); hold it, or swipe it right, to add or remove a favourite.
struct LiveChannelsView: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @State private var category: String?
    @State private var search = ""
    @State private var playing: PlayerRoute?

    var body: some View {
        Group {
            if let playlist = store.selected, case .loaded(let loaded) = store.state(of: playlist) {
                content(playlist, loaded)
            } else {
                StatusMessage(text: "Loading channels…", loading: true)
            }
        }
        .background(AmbientBackground())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .playerCover($playing)
    }

    private func content(_ playlist: Playlist, _ loaded: LoadedLibrary) -> some View {
        // Hidden categories left out, renamed ones under the user's name (Settings → Categories).
        let categories = store.visibleLiveCategories(loaded, in: playlist).map { CategoryItem(key: $0.key, title: $0.title) }
        let chosen = category ?? categories.first?.key
        let channels: [LiveChannel] = search.isEmpty
            ? loaded.channelsByCategory[chosen ?? ""] ?? []
            : Array(loaded.library.channels.filter { $0.title.localizedCaseInsensitiveContains(search) }.prefix(300))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("All channels")
                    .font(LumenFont.inter(wide ? 44 : 34, .semibold))
                    .foregroundStyle(LumenColors.textPrimary)
                Spacer()
                playlistMenu
            }
            .lumenGutter(wide)
            SearchField(text: $search, prompt: "Search channels")
                .lumenGutter(wide)
            if search.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories, id: \.key) { item in
                                ChipButton(title: item.title, selected: item.key == chosen, large: wide) {
                                    category = item.key
                                }
                                .id(item.key)
                            }
                        }
                        .lumenGutter(wide)
                    }
                    .onAppear { if let chosen { proxy.scrollTo(chosen, anchor: .center) } }
                }
            }
            List {
                ChannelRows(channels: channels, playing: $playing, showCategory: !search.isEmpty, loaded: loaded)
                if channels.isEmpty {
                    Text(search.isEmpty ? "No channels in this category." : "No channels match.")
                        .font(LumenFont.body)
                        .foregroundStyle(LumenColors.textSecondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, wide ? 36 : 8, for: .scrollContent)
            .id(chosen) // a new category starts at the top
        }
    }

    struct CategoryItem: Hashable {
        let key: String
        let title: String
    }

    @ViewBuilder
    private var playlistMenu: some View {
        // Only worth showing with more than one playlist.
        if store.playlists.count > 1 {
            Menu {
                Picker("Playlist", selection: Binding(
                    get: { store.selected?.id },
                    set: { store.selectedID = $0; category = nil }
                )) {
                    ForEach(store.playlists) { Text($0.name).tag(Optional($0.id)) }
                }
            } label: {
                Label(store.selected?.name ?? "Playlist", systemImage: "chevron.up.chevron.down")
                    .font(LumenFont.caption)
                    .foregroundStyle(LumenColors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glass(cornerRadius: 999)
            }
        }
    }
}

/// A glass search field (the system one can't be styled to match).
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(LumenColors.textSecondary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(LumenColors.textTertiary))
                .font(LumenFont.body)
                .foregroundStyle(LumenColors.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(LumenColors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glass(cornerRadius: 999)
        .onAppear { if autofocus { focused = true } }
    }
}

/// Channel rows; tapping one plays it full screen, zapping within [channels]. A pressed row
/// turns white with dark text, like a focused row on the TV.
struct ChannelRows: View {
    let channels: [LiveChannel]
    @Binding var playing: PlayerRoute?
    var showCategory = false
    var loaded: LoadedLibrary?
    @Environment(PlaylistStore.self) private var store

    var body: some View {
        let guide = store.guide(for: store.selected)
        ForEach(Array(channels.enumerated()), id: \.element.key) { index, channel in
            Button {
                playing = PlayerRoute(channels: channels, index: index)
            } label: {
                HStack(spacing: 14) {
                    ChannelLogo(url: channel.logoUrl, title: channel.title, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(channel.title).font(LumenFont.headline).lineLimit(1)
                            if let quality = channel.quality { QualityTag(text: quality) }
                        }
                        if let now = guide?.nowNext(channel)?.now {
                            Text(now.title).font(LumenFont.inter(14)).foregroundStyle(.secondary).lineLimit(1)
                            ProgressLine(fraction: now.progress(at: .now), height: 3, track: .gray.opacity(0.35))
                                .frame(width: 110)
                                .padding(.top, 2)
                        } else if showCategory, let title = categoryTitle(channel) {
                            Text(title).font(LumenFont.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if isFavourite(channel) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(LumenColors.accent)
                            .accessibilityLabel("Favourite")
                    }
                }
            }
            .buttonStyle(ChannelRowStyle())
            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // Hold a channel (or swipe right) to add or remove it from favourites.
            .contextMenu { favouriteButton(channel) }
            .swipeActions(edge: .leading) {
                favouriteButton(channel).tint(LumenColors.accent)
            }
        }
    }

    private func categoryTitle(_ channel: LiveChannel) -> String? {
        guard let loaded else { return channel.categoryName }
        return store.liveCategoryTitle(channel.categoryName, in: store.selected, loaded: loaded)
    }
}

/// White with dark text while pressed (the TV's focused row); clear otherwise.
struct ChannelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? LumenColors.background : LumenColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                configuration.isPressed ? Color.white : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension ChannelRows {
    func isFavourite(_ channel: LiveChannel) -> Bool {
        store.selected.map { store.isFavourite(channel, in: $0) } ?? false
    }

    @ViewBuilder
    func favouriteButton(_ channel: LiveChannel) -> some View {
        if let playlist = store.selected {
            if store.isFavourite(channel, in: playlist) {
                Button("Remove from favourites", systemImage: "star.slash") {
                    store.toggleFavourite(channel, in: playlist)
                }
            } else {
                Button("Add to favourites", systemImage: "star") {
                    store.toggleFavourite(channel, in: playlist)
                }
            }
        }
    }
}

/// Reorder (drag the handles) or remove favourites, the iOS way.
struct FavouritesEditView: View {
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [LiveChannel] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(channels, id: \.key) { channel in
                    HStack(spacing: 14) {
                        ChannelLogo(url: channel.logoUrl, title: channel.title, size: 36)
                        Text(channel.title).lineLimit(1)
                    }
                }
                .onMove { from, to in
                    channels.move(fromOffsets: from, toOffset: to)
                    store.setFavourites(channels, in: playlist)
                }
                .onDelete { offsets in
                    channels.remove(atOffsets: offsets)
                    store.setFavourites(channels, in: playlist)
                }
            }
            .font(LumenFont.body)
            // Always in edit mode: drag handles and delete buttons show straight away.
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Favourites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { channels = store.favourites(in: playlist) }
        }
    }
}

extension View {
    /// Presents the full-screen player for [route] (set by tapping a channel row).
    func playerCover(_ route: Binding<PlayerRoute?>) -> some View {
        fullScreenCover(item: route) { route in
            LivePlayerView(channels: route.channels, startIndex: route.index)
        }
    }
}

struct PlayerRoute: Identifiable {
    let id = UUID()
    let channels: [LiveChannel]
    let index: Int
}

/// A small 16:9 channel picture for rows and the player bar.
struct ChannelLogo: View {
    let url: String?
    let title: String
    var size: CGFloat = 44

    var body: some View {
        ChannelArt(logoUrl: url, title: title, cornerRadius: 8)
            .frame(width: size * 16 / 9, height: size)
    }
}

struct QualityTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LumenFont.caption)
            .foregroundStyle(LumenColors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(LumenColors.textTertiary, lineWidth: 1))
    }
}
