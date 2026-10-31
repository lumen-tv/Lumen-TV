import SwiftUI

struct SettingsView: View {
    @Environment(PlaylistStore.self) private var store
    @State private var addingPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    ForEach(store.playlists) { playlist in
                        NavigationLink { PlaylistSettingsView(playlist: playlist) } label: { PlaylistRow(playlist: playlist) }
                            .swipeActions {
                                Button("Remove", role: .destructive) { store.remove(playlist) }
                            }
                            .contextMenu {
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    Task { await store.refresh(playlist) }
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) { store.remove(playlist) }
                            }
                    }
                    Button("Add playlist", systemImage: "plus") { addingPlaylist = true }
                }
                if let playlist = store.selected {
                    Section {
                        NavigationLink("Live TV") { CategorySettingsView(kind: .live, playlist: playlist) }
                        if playlist.kind == .xtream {
                            NavigationLink("Movies") { CategorySettingsView(kind: .movies, playlist: playlist) }
                            NavigationLink("Series") { CategorySettingsView(kind: .series, playlist: playlist) }
                        }
                    } header: {
                        Text("Categories")
                    } footer: {
                        Text("Hide categories you never watch, or give them your own names.")
                    }
                }
                Section {
                    NavigationLink { RatingsSettingsView() } label: {
                        LabeledContent("Ratings", value: Omdb.shared.key == nil ? "Off" : "On")
                    }
                } footer: {
                    Text("IMDb and Rotten Tomatoes scores on film and series pages, with your own free OMDb key.")
                }
                Section("Check this device") {
                    NavigationLink("Test video playback") { TestPlayerView() }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.version)
                    Text("Lumen is a player for your own TV subscription. It doesn't provide any channels or content.")
                        .foregroundStyle(LumenColors.textSecondary)
                    NavigationLink("Licences") { LicencesView() }
                }
            }
            .font(LumenFont.body)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Settings")
            .sheet(isPresented: $addingPlaylist) { AddPlaylistView() }
        }
    }
}

private struct PlaylistRow: View {
    @Environment(PlaylistStore.self) private var store
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(playlist.name).foregroundStyle(LumenColors.textPrimary)
            Text(status)
                .font(LumenFont.caption)
                .foregroundStyle(LumenColors.textSecondary)
        }
    }

    private var status: String {
        let kind = playlist.kind == .xtream ? "Xtream" : "M3U"
        switch store.state(of: playlist) {
        case .idle, .loading: return "\(kind) · \(playlist.host) · loading…"
        case .loaded(let loaded): return "\(kind) · \(playlist.host) · \(loaded.library.channels.count) channels"
        case .failed(let message): return message
        }
    }
}

struct LicencesView: View {
    var body: some View {
        List {
            Section("Inter") {
                Text("Typeface by Rasmus Andersson, under the SIL Open Font License 1.1.")
            }
            Section("VLCKit") {
                Text("Plays films and episodes. By VideoLAN and the VLC authors, under the GNU Lesser General Public License 2.1.")
            }
        }
        .font(LumenFont.body)
        .scrollContentBackground(.hidden)
        .background(AmbientBackground())
        .navigationTitle("Licences")
    }
}

extension Bundle {
    /// "0.1.0 (1)".
    var version: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Playlist

/// One playlist: name, refresh, login or link, guide link, remove. As on the TV's
/// Settings → Playlists: a new login is only saved if the channels load with it.
struct PlaylistSettingsView: View {
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var link = ""
    @State private var guide = ""
    @State private var saving = false
    @State private var message: String?
    @State private var confirmRemove = false

    /// The latest copy (the name or kind may have changed since the list was drawn).
    private var current: Playlist { store.playlists.first { $0.id == playlist.id } ?? playlist }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .onSubmit { store.rename(current, to: name) }
            }
            Section {
                Button("Refresh channels, films and guide", systemImage: "arrow.clockwise") {
                    Task { await store.refreshEverything(current) }
                }
                .disabled(isLoading)
            } footer: {
                Text(status)
            }
            if current.kind == .xtream {
                Section {
                    TextField("Server", text: $server).keyboardType(.URL)
                    TextField("Username", text: $username)
                    SecureField("New password (blank keeps the old one)", text: $password)
                    saveButton("Save login") {
                        try await store.changeXtream(current, server: server, username: username, password: password)
                        password = ""
                    }
                    .disabled(server.isEmpty || username.isEmpty)
                } header: {
                    Text("Xtream login")
                } footer: {
                    Text("Lumen checks the new login by loading the channels. If that fails, the old one stays.")
                }
            } else {
                Section {
                    // The old link is never shown: it can hold a password.
                    TextField("New playlist link", text: $link).keyboardType(.URL)
                    saveButton("Save link") {
                        try await store.changeM3u(current, link: link)
                        link = ""
                    }
                    .disabled(link.isEmpty)
                } header: {
                    Text("Playlist link")
                } footer: {
                    Text("Lumen checks the new link by loading the channels. If that fails, the old one stays.")
                }
            }
            Section {
                TextField("Guide link (XMLTV)", text: $guide).keyboardType(.URL)
                Button("Save guide link") {
                    Task { await store.setGuideUrl(current, guide); message = "Guide link saved." }
                }
            } header: {
                Text("TV guide")
            } footer: {
                Text(current.kind == .xtream ? "Leave blank to use your provider's own guide." : "Leave blank to use the guide named in the playlist.")
            }
            if let message {
                Section { Text(message).foregroundStyle(LumenColors.textSecondary) }
            }
            Section {
                Button("Remove playlist", role: .destructive) { confirmRemove = true }
            }
        }
        .font(LumenFont.body)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollContentBackground(.hidden)
        .background(AmbientBackground())
        .navigationTitle(current.name)
        .disabled(saving)
        .onAppear {
            name = current.name
            if let details = store.xtreamDetails(current) { server = details.server; username = details.username }
            guide = store.guideUrl(current) ?? ""
        }
        .onDisappear { if name != current.name { store.rename(current, to: name) } }
        .confirmationDialog("Remove \(current.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.remove(current)
                dismiss()
            }
        } message: {
            Text("Its favourites, My List and progress go too.")
        }
    }

    private func saveButton(_ title: String, _ action: @escaping () async throws -> Void) -> some View {
        Button {
            saving = true
            message = nil
            Task {
                do {
                    try await action()
                    message = "Saved. Channels loaded."
                } catch {
                    message = PlaylistStore.message(for: error)
                }
                saving = false
            }
        } label: {
            HStack {
                Text(title)
                if saving { Spacer(); ProgressView() }
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = store.state(of: current) { return true }
        return false
    }

    private var status: String {
        switch store.state(of: current) {
        case .idle, .loading: "Loading channels…"
        case .loaded(let loaded): "\(loaded.library.channels.count) channels"
        case .failed(let message): message
        }
    }
}

// MARK: - Categories

/// Every category with a tick (tap to show or hide), a search, Show all / Hide all (acting on the
/// matches only), and hold or swipe to rename. Like the TV's Settings → categories.
struct CategorySettingsView: View {
    enum Kind { case live, movies, series }
    let kind: Kind
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @State private var search = ""
    @State private var renaming: Item?
    @State private var newName = ""

    struct Item: Identifiable, Hashable {
        let key: String
        let title: String
        let count: Int
        var id: String { key }
    }

    private var items: [Item] {
        switch kind {
        case .live:
            guard case .loaded(let loaded) = store.state(of: playlist) else { return [] }
            return loaded.categories.map { Item(key: PlaylistStore.liveCategoryKey($0.name), title: $0.title, count: Int($0.channelCount)) }
        case .movies, .series:
            guard case .loaded(let index) = store.vodState(of: playlist) else { return [] }
            let movies = kind == .movies
            return (movies ? index.movieCategories : index.seriesCategories).map {
                Item(key: movies ? PlaylistStore.movieCategoryKey($0.id) : PlaylistStore.seriesCategoryKey($0.id),
                     title: $0.title, count: Int($0.count))
            }
        }
    }

    private var shown: [Item] {
        search.isEmpty ? items : items.filter {
            $0.title.localizedCaseInsensitiveContains(search) || store.label($0.key, fallback: $0.title, in: playlist).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Text("Nothing loaded yet.").foregroundStyle(LumenColors.textSecondary)
            }
            ForEach(shown) { item in
                let hidden = store.isHidden(item.key, in: playlist)
                Button {
                    store.setHidden([item.key], !hidden, in: playlist)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: hidden ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(hidden ? LumenColors.textTertiary : LumenColors.accent)
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.label(item.key, fallback: item.title, in: playlist))
                                .foregroundStyle(hidden ? LumenColors.textSecondary : LumenColors.textPrimary)
                            if store.label(item.key, fallback: item.title, in: playlist) != item.title {
                                Text(item.title).font(LumenFont.caption).foregroundStyle(LumenColors.textTertiary)
                            }
                        }
                        Spacer()
                        Text("\(item.count)").font(LumenFont.caption).foregroundStyle(LumenColors.textTertiary)
                    }
                }
                .contextMenu { renameButton(item) }
                .swipeActions { renameButton(item).tint(LumenColors.accent) }
            }
        }
        .font(LumenFont.body)
        .scrollContentBackground(.hidden)
        .background(AmbientBackground())
        .navigationTitle(title)
        .searchable(text: $search, prompt: "Search categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Show all", systemImage: "eye") { store.setHidden(shown.map(\.key), false, in: playlist) }
                    Button("Hide all", systemImage: "eye.slash") { store.setHidden(shown.map(\.key), true, in: playlist) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(search.isEmpty ? "Show or hide all" : "Show or hide the matches")
            }
        }
        .alert("Rename category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { item in
            TextField(item.title, text: $newName)
            Button("Save") { store.rename(item.key, to: newName, fallback: item.title, in: playlist) }
            Button("Use the original name") { store.rename(item.key, to: "", fallback: item.title, in: playlist) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Only the name Lumen shows changes. The provider's is \"\(item.title)\".")
        }
    }

    private func renameButton(_ item: Item) -> some View {
        Button("Rename", systemImage: "pencil") {
            newName = store.label(item.key, fallback: item.title, in: playlist)
            renaming = item
        }
    }

    private var title: String {
        switch kind {
        case .live: "Live TV categories"
        case .movies: "Movie categories"
        case .series: "Series categories"
        }
    }
}

// MARK: - Ratings

/// The user's own OMDb key (free at omdbapi.com), checked before it's saved, kept in the Keychain.
struct RatingsSettingsView: View {
    @State private var key = ""
    @State private var hasKey = Omdb.shared.key != nil
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField(hasKey ? "Key saved. Type a new one to change it" : "Your OMDb key", text: $key)
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Check and save")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if hasKey {
                    Button("Remove key", role: .destructive) {
                        Omdb.shared.setKey(nil)
                        hasKey = false
                        message = "Ratings are off."
                    }
                }
            } footer: {
                Text("With a key, film and series pages show IMDb and Rotten Tomatoes scores and the age rating. Get a free key at omdbapi.com (1,000 lookups a day).")
            }
            if let message {
                Section { Text(message).foregroundStyle(LumenColors.textSecondary) }
            }
            Section {
                Link("Get a free key", destination: URL(string: "https://www.omdbapi.com/apikey.aspx")!)
            }
        }
        .font(LumenFont.body)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollContentBackground(.hidden)
        .background(AmbientBackground())
        .navigationTitle("Ratings")
    }

    private func save() async {
        checking = true
        defer { checking = false }
        switch await Omdb.shared.check(key) {
        case .works:
            Omdb.shared.setKey(key)
            key = ""
            hasKey = true
            message = "The key works. Ratings are on."
        case .rejected:
            message = "OMDb didn't accept that key. Check it in the email from OMDb (it needs activating first)."
        case .unreachable:
            message = "Couldn't reach OMDb. Check the connection and try again."
        }
    }
}
