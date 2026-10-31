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
    /// The bar is in search mode: it has turned into a search field and the results cover the
    /// open tab (no separate search page, Hayat 2026-10-31).
    @State private var searching = false
    @State private var query = ""
    /// Film and series pages opened from the results.
    @State private var searchPath = NavigationPath()
    /// A full-screen page in the open tab (the iPhone TV guide) asked for the bar to go.
    @State private var barHidden = false
    /// iPad: a pushed page is showing, so the floating pill steps aside for its back button.
    @State private var topBarHidden = false
    @State private var topBarHeight: CGFloat = 86
    /// The glow colour each tab's top page shows, painted behind the iPad's pill so it meets the
    /// page without a line.
    @State private var tints = AmbientTints()

    private var wide: Bool { UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular }

    var body: some View {
        // iPad: the pill floats over the page, as on the TV, so each page's colours and pictures
        // run up to the top of the screen. Tab pages leave room for it themselves
        // (`.belowTopBar()`); pushed pages (a film, All channels, the guide…) hide it and use
        // their back button (`.pushedPage()`). An earlier version put the pill in its own band
        // above the pages, which read as a separate strip (Hayat 2026-10-31).
        ZStack(alignment: .top) {
            ZStack {
                ForEach(AppTab.allCases) { item in
                    if opened.contains(item) {
                        screen(for: item)
                            .opacity(tab == item ? 1 : 0)
                            .allowsHitTesting(tab == item)
                            .accessibilityHidden(tab != item)
                            // Only the open tab may hide the bar.
                            .transformPreference(TabBarHiddenKey.self) { if tab != item { $0 = false } }
                            .transformPreference(TopBarHiddenKey.self) { if tab != item { $0 = false } }
                            .environment(\.ambientTab, item.rawValue)
                    }
                }
                if searching {
                    SearchView(query: query, path: $searchPath)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.topBarSpace, wide ? topBarHeight : 0)
            if wide, !topBarHidden {
                TopTabBar(tab: tab, select: select, searching: searching, query: $query,
                          search: startSearch, cancel: endSearch)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarHeight = $0 }
                    .transition(.opacity)
            }
        }
        // Only shows where a page doesn't cover the screen. `.id(tab)`: a tab switch swaps it at
        // once, like the pages themselves.
        .background(AmbientBackground(tint: tints.tint(for: tab.rawValue) ?? LumenColors.ambientCool).id(tab))
        .environment(\.ambientTints, tints)
        .onPreferenceChange(TabBarHiddenKey.self) { barHidden = $0 }
        .onPreferenceChange(TopBarHiddenKey.self) { topBarHidden = $0 }
        .animation(.easeOut(duration: 0.2), value: topBarHidden)
        // iPhone: the floating bar; safeAreaInset makes scroll views inside every tab end above it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A film opened from the results has the whole screen, with its back button.
            if !wide, !barHidden, !(searching && !searchPath.isEmpty) {
                BottomTabBar(tab: tab, select: select, searching: searching, query: $query,
                             search: startSearch, cancel: endSearch)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: barHidden)
        .hideTopScrollEdgeEffect()
        // The keyboard covers the bar instead of pushing it up, except while searching: then
        // the field rides up on top of the keyboard.
        .ignoresSafeArea(.keyboard, edges: searching ? [] : .bottom)
        .environment(\.lumenWide, wide)
        .environment(\.openSearch, startSearch)
    }

    private func select(_ item: AppTab) {
        if searching { endSearch() }
        opened.insert(item)
        tab = item
    }

    private func startSearch() {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { searching = true }
    }

    private func endSearch() {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            searching = false
            query = ""
            searchPath = NavigationPath()
        }
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
    let searching: Bool
    @Binding var query: String
    let search: () -> Void
    let cancel: () -> Void
    @Namespace private var bar

    var body: some View {
        HStack(spacing: 8) {
            if searching {
                // The tabs make way and the bar itself becomes the search field.
                BarSearchField(text: $query, font: LumenFont.inter(17, .regular))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .padding(.horizontal, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color(hex: 0x282A32).opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .matchedGeometryEffect(id: "bar", in: bar)
                    .transition(.opacity)
                roundButton("xmark", label: "Cancel search", action: cancel)
                    .matchedGeometryEffect(id: "button", in: bar)
            } else {
                tabs
                    .matchedGeometryEffect(id: "bar", in: bar)
                    .transition(.opacity)
                // Search sits apart from the tabs in its own glass circle.
                roundButton("magnifyingglass", label: "Search", action: search)
                    .matchedGeometryEffect(id: "button", in: bar)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .animation(.easeOut(duration: 0.18), value: tab)
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(LumenColors.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 58, height: 58)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color(hex: 0x282A32).opacity(0.6), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
    let searching: Bool
    @Binding var query: String
    let search: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                if searching {
                    // The pill widens into a search field; the tabs fold away until Cancel.
                    BarSearchField(text: $query, font: LumenFont.inter(17, .regular))
                        .padding(.leading, 14)
                        .frame(width: 460)
                        .transition(.opacity)
                    pillButton(on: true, label: "Cancel", action: cancel) {
                        Text("Cancel").font(LumenFont.inter(17, .medium))
                    }
                    .transition(.opacity)
                } else {
                    pillButton(on: false, label: "Search", action: search) {
                        Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                    }
                    ForEach(AppTab.allCases.filter { $0 != .settings }) { item in
                        pillButton(on: item == tab, label: item.title, action: { select(item) }) {
                            Text(item.title).font(LumenFont.inter(17, .medium))
                        }
                    }
                    .transition(.opacity)
                    pillButton(on: tab == .settings, label: "Settings", action: { select(.settings) }) {
                        Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold))
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 41)
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

/// The search field inside the tab bar: takes the keyboard as soon as it appears.
struct BarSearchField: View {
    @Binding var text: String
    let font: Font
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LumenColors.textSecondary)
            TextField("Search", text: $text,
                      prompt: Text("Channels, films and series").foregroundStyle(LumenColors.textTertiary))
                .font(font)
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
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear {
            // After the bar's expand animation has started, so the keyboard doesn't fight it.
            // Not when coming back from a film opened from the results.
            if text.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
        }
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

/// iPad: set by pushed pages, which hide the floating top pill (they have a back button instead).
struct TopBarHiddenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// A page pushed inside a tab: on iPad the top pill steps aside for its back button.
    func pushedPage() -> some View {
        preference(key: TopBarHiddenKey.self, value: true)
    }

    /// A tab's first page: on iPad its scrolling content starts below the floating pill, while
    /// its background still runs up behind it.
    func belowTopBar() -> some View {
        modifier(BelowTopBar())
    }
}

private struct BelowTopBar: ViewModifier {
    @Environment(\.topBarSpace) private var space

    func body(content: Content) -> some View {
        content.contentMargins(.top, space, for: .scrollContent)
    }
}
