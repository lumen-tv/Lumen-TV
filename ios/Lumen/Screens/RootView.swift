import SwiftUI

/// Lumen's tabs, as on the TV: Live TV · Movies · Series · My List, plus Settings.
/// One app for iPhone and iPad: a full-width iPad window gets the TV's glass pill at the top
/// with the clock on the right; iPhone (and narrow iPad split screen) gets a floating glass
/// bar at the bottom, where the thumb is. The system TabView isn't used because its look can't
/// be changed to match the TV.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab: AppTab = .live
    /// Tabs opened so far. Each stays alive once opened (hidden, not removed), so switching back
    /// keeps its scroll position and pushed pages, as a real tab bar does.
    @State private var opened: Set<AppTab> = [.live]
    @State private var searching = false
    /// A full-screen page in the open tab (the iPhone TV guide) asked for the bar to go.
    @State private var barHidden = false

    private var wide: Bool { UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular }

    var body: some View {
        // iPad: the pill sits above the tabs in a VStack, so pages start below it. (As a top
        // safeAreaInset, the pages' NavigationStacks with hidden bars ignored it and slid their
        // first rows under the pill: Hayat's iPad screenshots 2026-10-31.)
        VStack(spacing: 0) {
            if wide {
                TopTabBar(tab: tab, select: select, search: { searching = true })
            }
            ZStack {
                ForEach(AppTab.allCases) { item in
                    if opened.contains(item) {
                        screen(for: item)
                            .opacity(tab == item ? 1 : 0)
                            .allowsHitTesting(tab == item)
                            .accessibilityHidden(tab != item)
                            // Only the open tab may hide the bar.
                            .transformPreference(TabBarHiddenKey.self) { if tab != item { $0 = false } }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AmbientBackground())
        .onPreferenceChange(TabBarHiddenKey.self) { barHidden = $0 }
        // iPhone: the floating bar; safeAreaInset makes scroll views inside every tab end above it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !wide, !barHidden {
                BottomTabBar(tab: tab, select: select, search: { searching = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: barHidden)
        .hideTopScrollEdgeEffect()
        // The keyboard covers the bar instead of pushing it up.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .environment(\.lumenWide, wide)
        .environment(\.openSearch, { searching = true })
        .sheet(isPresented: $searching) {
            SearchView().environment(\.lumenWide, wide).hideTopScrollEdgeEffect()
        }
    }

    private func select(_ item: AppTab) {
        opened.insert(item)
        tab = item
    }

    @ViewBuilder
    private func screen(for item: AppTab) -> some View {
        switch item {
        case .live: HomeView()
        case .movies: VodTabView(kind: .movies)
        case .series: VodTabView(kind: .series)
        case .myList: MyListView()
        case .settings: SettingsView()
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case live, movies, series, myList, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live TV"
        case .movies: "Movies"
        case .series: "Series"
        case .myList: "My List"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .live: "tv"
        case .movies: "film"
        case .series: "play.rectangle.on.rectangle"
        case .myList: "heart"
        case .settings: "gearshape"
        }
    }
}

/// iPhone: a floating glass bar; the open tab is a white pill with dark text (the TV's focus look).
struct BottomTabBar: View {
    let tab: AppTab
    let select: (AppTab) -> Void
    let search: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tabs
            // Search sits apart from the tabs in its own glass circle: it opens over the open tab
            // instead of being a place of its own.
            Button(action: search) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(LumenColors.textPrimary)
                    .frame(width: 58, height: 58)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color(hex: 0x282A32).opacity(0.6), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .animation(.easeOut(duration: 0.18), value: tab)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { item in
                let on = item == tab
                Button { select(item) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: on ? item.icon + ".fill" : item.icon)
                            .font(.system(size: 17, weight: .medium))
                            .frame(height: 20)
                        Text(item.title).font(LumenFont.inter(11, .medium)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(on ? LumenColors.background : LumenColors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 7)
                    .background(on ? Color.white : Color.clear, in: Capsule())
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        // A real blur here (cheap on a phone), tinted dark, so rows scrolling under stay readable.
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color(hex: 0x282A32).opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// iPad: the TV's top bar. One centred glass pill (search · tabs · settings) and the clock.
struct TopTabBar: View {
    let tab: AppTab
    let select: (AppTab) -> Void
    let search: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                pillButton(on: false, label: "Search", action: search) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                }
                ForEach(AppTab.allCases.filter { $0 != .settings }) { item in
                    pillButton(on: item == tab, label: item.title, action: { select(item) }) {
                        Text(item.title).font(LumenFont.inter(17, .medium))
                    }
                }
                pillButton(on: tab == .settings, label: "Settings", action: { select(.settings) }) {
                    Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold))
                }
            }
            .padding(6)
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
            .glass(cornerRadius: 999)
            HStack {
                Spacer()
                ClockView()
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.18), value: tab)
    }

    private func pillButton<C: View>(on: Bool, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(on ? LumenColors.textPrimary : LumenColors.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(on ? Color.white.opacity(0.16) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A tab with nothing in it yet: Lumen ships with no channels (an App Store rule), so this is
/// what everyone sees first.
struct EmptyTab: View {
    let title: String
    let message: String
    @State private var addingPlaylist = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(LumenColors.textSecondary)
            Text("Nothing here yet")
                .font(LumenFont.title)
                .foregroundStyle(LumenColors.textPrimary)
            Text(message)
                .font(LumenFont.body)
                .foregroundStyle(LumenColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Add playlist") { addingPlaylist = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $addingPlaylist) { AddPlaylistView() }
    }
}

/// Loading, failed and "nothing to show" states, centred.
struct StatusMessage: View {
    let text: String
    var loading = false
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if loading { ProgressView().tint(.white) }
            Text(text)
                .font(LumenFont.body)
                .foregroundStyle(LumenColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let retry {
                Button("Try again", action: retry).buttonStyle(GlassButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Set by a page that wants the whole screen on iPhone (`.tabBarHidden()`), like a pushed
/// page hiding the system tab bar. The bar comes back when the page is popped.
struct TabBarHiddenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    func tabBarHidden(_ hidden: Bool = true) -> some View {
        preference(key: TabBarHiddenKey.self, value: hidden)
    }
}
