import Shared
import SwiftUI

/// The My List tab, as on the TV since 0.8.0: everything you saved with the heart, newest first,
/// with All / Films / Series. Hold a poster to remove it.
struct MyListView: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "All", films = "Films", series = "Series"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let playlist = store.selected {
                    content(playlist).vodDestinations(playlist)
                } else {
                    EmptyTab(title: "My List", message: "Films and series you save with the heart show up here.")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let all = store.myList(in: playlist)
        let items = all.filter {
            switch filter {
            case .all: true
            case .films: $0.kind == .movie
            case .series: $0.kind == .series
            }
        }
        let index: VodIndex? = {
            if case .loaded(let loaded) = store.vodState(of: playlist) { return loaded }
            return nil
        }()
        let posterWidth: CGFloat = wide ? 160 : 104

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("My List").font(LumenFont.inter(wide ? 44 : 34, .semibold)).foregroundStyle(LumenColors.textPrimary)
                    Text(all.count == 1 ? "1 title" : "\(all.count) titles")
                        .font(LumenFont.body).foregroundStyle(LumenColors.textSecondary)
                    Spacer()
                    if wide { chips }
                }
                if !wide { chips }
                if items.isEmpty {
                    Text(all.isEmpty
                         ? "Tap the heart on a film or series to save it here."
                         : "Nothing in this filter yet.")
                        .font(LumenFont.body)
                        .foregroundStyle(LumenColors.textSecondary)
                        .padding(.top, 30)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: posterWidth), spacing: wide ? 20 : 12, alignment: .top)],
                        spacing: wide ? 26 : 18
                    ) {
                        ForEach(items, id: \.self) { item in
                            cell(item, index: index, width: posterWidth)
                                .contextMenu {
                                    Button("Remove from My List", systemImage: "heart.slash", role: .destructive) {
                                        store.toggleMyList(item, in: playlist)
                                    }
                                }
                        }
                    }
                    .buttonStyle(TileButtonStyle())
                    Text("Hold a poster to remove it")
                        .font(LumenFont.caption)
                        .foregroundStyle(LumenColors.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lumenGutter(wide)
            .padding(.top, wide ? 24 : 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(AmbientBackground())
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases, id: \.self) { item in
                ChipButton(title: item.rawValue, selected: filter == item, large: wide) { filter = item }
            }
        }
    }

    /// Opens the film or series page once the films have loaded; until then the saved poster shows.
    @ViewBuilder
    private func cell(_ item: MyListItem, index: VodIndex?, width: CGFloat) -> some View {
        let poster = Poster(url: item.posterUrl, title: item.title, subtitle: item.kind == .series ? "Series" : nil, width: width)
        if item.kind == .movie, let movie = index?.movieById[item.id] {
            NavigationLink(value: movie) { poster }
        } else if item.kind == .series, let series = index?.seriesById[item.id] {
            NavigationLink(value: series) { poster }
        } else {
            poster.opacity(0.6)
        }
    }
}
