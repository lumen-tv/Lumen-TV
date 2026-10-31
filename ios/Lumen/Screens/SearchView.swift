import Shared
import SwiftUI

/// Search across the playlist: channels, films and series (the search icon on iPad's top bar,
/// or at the top of Home and the Movies and Series tabs on iPhone).
struct SearchView: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results = Results()
    @State private var playing: PlayerRoute?

    struct Results {
        var channels: [LiveChannel] = []
        var movies: [Movie] = []
        var series: [Series] = []
        var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    SearchField(text: $query, prompt: "Channels, films and series", autofocus: true)
                    if query.trimmingCharacters(in: .whitespaces).count < 2 {
                        hint("Type at least two letters.")
                    } else if results.isEmpty {
                        hint("Nothing matches “\(query)”.")
                    } else {
                        sections
                    }
                }
                .lumenGutter(wide)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(AmbientBackground())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .modifier(Destinations(playlist: store.selected))
        }
        .playerCover($playing)
        // Waits for a pause in typing (35k films is a lot to scan on every key).
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = search(query.trimmingCharacters(in: .whitespaces))
        }
    }

    @ViewBuilder
    private var sections: some View {
        if !results.channels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Channels")
                VStack(spacing: 2) {
                    ChannelRows(channels: results.channels, playing: $playing, showCategory: true, loaded: loaded)
                }
                .padding(.horizontal, -12)
            }
        }
        if !results.movies.isEmpty {
            resultRow("Films") {
                ForEach(results.movies, id: \.id) { movie in
                    NavigationLink(value: movie) {
                        Poster(url: movie.posterUrl, title: movie.title, subtitle: movie.year.map { "\($0.intValue)" }, width: wide ? 150 : 108)
                    }
                }
            }
        }
        if !results.series.isEmpty {
            resultRow("Series") {
                ForEach(results.series, id: \.id) { show in
                    NavigationLink(value: show) {
                        Poster(url: show.posterUrl, title: show.title, subtitle: show.year.map { "\($0.intValue)" }, width: wide ? 150 : 108)
                    }
                }
            }
        }
    }

    private func resultRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12, content: content)
            }
            .buttonStyle(TileButtonStyle())
            .padding(.horizontal, wide ? -48 : -20)
            .contentMargins(.horizontal, wide ? 48 : 20, for: .scrollContent)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(LumenFont.body).foregroundStyle(LumenColors.textSecondary)
    }

    private var loaded: LoadedLibrary? {
        guard let playlist = store.selected, case .loaded(let loaded) = store.state(of: playlist) else { return nil }
        return loaded
    }

    private func search(_ text: String) -> Results {
        guard text.count >= 2, let playlist = store.selected else { return Results() }
        var results = Results()
        if let loaded {
            results.channels = Array(loaded.library.channels.lazy.filter { $0.title.localizedCaseInsensitiveContains(text) }.prefix(20))
        }
        if case .loaded(let index) = store.vodState(of: playlist) {
            results.movies = Array(index.movieById.values.lazy.filter { $0.title.localizedCaseInsensitiveContains(text) }.prefix(40))
                .sorted { $0.title.count < $1.title.count }
            results.series = Array(index.seriesById.values.lazy.filter { $0.title.localizedCaseInsensitiveContains(text) }.prefix(40))
                .sorted { $0.title.count < $1.title.count }
        }
        return results
    }

    /// Film and series pages open inside the search sheet.
    private struct Destinations: ViewModifier {
        let playlist: Playlist?

        @ViewBuilder
        func body(content: Content) -> some View {
            if let playlist {
                content.vodDestinations(playlist)
            } else {
                content
            }
        }
    }
}
