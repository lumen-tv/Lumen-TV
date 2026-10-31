import Shared
import SwiftUI

/// The TV guide: channels down the left, time across, a white line at now. A drag scrolls
/// either up/down or sideways, never both (Hayat 2026-10-31: the free 2-way pan felt like an
/// overlay); the channel column and the times stay put. Tap a programme to see its details, double-tap it to watch that channel
/// (Hayat 2026-10-31: no Watch button on iPhone). Opened from Home's "TV guide".
///
/// iPhone: a details card slides up over the grid. iPad: the TV's glass panel sits above the
/// grid with the channel playing muted on its right.
struct GuideView: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @State private var source: Source?
    @State private var selected: Selection?
    @State private var playing: PlayerRoute?
    @State private var position = ScrollPosition(edge: .leading)
    @State private var scrollX: CGFloat = 0
    @State private var now = Date.now
    /// The grid starts at the last half hour, so it opens on what's on now, and runs 30 hours
    /// (the guide keeps 36).
    @State private var windowStart = GuideView.halfHour(before: .now)
    @State private var preview = LivePlayerModel(muted: true)
    @State private var previewTask: Task<Void, Never>?

    enum Source: Hashable {
        case favourites
        case category(String)
    }

    struct Selection: Equatable {
        let channelKey: String
        let programmeStart: Int64?
    }

    // Sizes: points per minute of programme, row height, channel tile width.
    private var ppm: CGFloat { wide ? 6 : 3.4 }
    private var rowHeight: CGFloat { wide ? 66 : 58 }
    private var tileWidth: CGFloat { wide ? 130 : 70 }
    private let gap: CGFloat = 8
    private let hours: Double = 30

    var body: some View {
        Group {
            if let playlist = store.selected, case .loaded(let loaded) = store.state(of: playlist) {
                content(playlist, loaded)
            } else {
                StatusMessage(text: "Loading channels…", loading: true)
            }
        }
        .background(AmbientBackground(tint: tint))
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(wide ? "TV guide" : "")
        .navigationBarTitleDisplayMode(.inline)
        .playerCover($playing)
        // iPhone: the guide takes the whole screen (back button to leave), so the details card
        // has the bottom to itself instead of sitting under the floating tab bar.
        .tabBarHidden(!wide)
        .task {
            // Moves the now line (and "starts in …") along.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
            }
        }
        .onChange(of: playing == nil) { _, closed in
            // One stream at a time: providers often allow a single connection.
            if !closed { previewTask?.cancel(); preview.stop() }
        }
        .onDisappear { previewTask?.cancel(); preview.stop() }
    }

    // MARK: Layout

    private func content(_ playlist: Playlist, _ loaded: LoadedLibrary) -> some View {
        let favourites = store.favourites(in: playlist)
        let current: Source? = source ?? (favourites.isEmpty ? store.visibleLiveCategories(loaded, in: playlist).first.map { Source.category($0.key) } : Source.favourites)
        let rows: [LiveChannel] = switch current {
        case .favourites: favourites
        case .category(let name): loaded.channelsByCategory[name] ?? []
        case nil: []
        }
        let guide = store.guide(for: playlist)
        return VStack(alignment: .leading, spacing: 0) {
            if wide {
                panel(rows: rows, guide: guide)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 16)
            } else {
                phoneHeader(current: current, favourites: favourites, loaded: loaded)
            }
            status(playlist)
            grid(rows: rows, guide: guide)
                // Part of the layout, above the tab bar: the grid ends where the card starts.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !wide, let selection = selected, let channel = rows.first(where: { $0.key == selection.channelKey }) {
                        DetailsCard(channel: channel, programme: programme(selection, guide), now: now) { selected = nil }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .animation(.easeOut(duration: 0.2), value: selected)
        .onChange(of: selected) { _, selection in
            if wide { startPreview(selection.flatMap { s in rows.first { $0.key == s.channelKey } }) }
        }
        .onAppear {
            if wide, selected == nil, let first = rows.first {
                selected = Selection(channelKey: first.key, programmeStart: guide?.nowNext(first, at: now)?.now?.start)
            }
        }
        .toolbar {
            if wide {
                ToolbarItem(placement: .topBarTrailing) { sourceMenu(current: current, favourites: favourites, loaded: loaded) }
            }
        }
    }

    private func phoneHeader(current: Source?, favourites: [LiveChannel], loaded: LoadedLibrary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TV guide").font(LumenFont.inter(34, .semibold)).foregroundStyle(LumenColors.textPrimary)
                Spacer()
                sourceMenu(current: current, favourites: favourites, loaded: loaded)
            }
            dayChips
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var dayChips: some View {
        let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let shown = windowStart.addingTimeInterval(Double(scrollX / ppm) * 60)
        return HStack(spacing: 8) {
            ChipButton(title: "Today", selected: shown < tomorrow, large: wide) { scroll(to: now.addingTimeInterval(-15 * 60)) }
            // Tomorrow from 6 AM: nothing much is on before.
            ChipButton(title: "Tomorrow", selected: shown >= tomorrow, large: wide) { scroll(to: tomorrow.addingTimeInterval(6 * 3600)) }
            ChipButton(title: "Now", selected: false, large: wide) { scroll(to: now.addingTimeInterval(-15 * 60)) }
        }
    }

    private func sourceMenu(current: Source?, favourites: [LiveChannel], loaded: LoadedLibrary) -> some View {
        Menu {
            Picker("Channels", selection: Binding(get: { current }, set: { source = $0; selected = nil })) {
                if !favourites.isEmpty { Text("Favourites").tag(Optional(Source.favourites)) }
                if let playlist = store.selected {
                    ForEach(store.visibleLiveCategories(loaded, in: playlist), id: \.key) { category in
                        Text(category.title).tag(Optional(Source.category(category.key)))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(current, loaded)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
            }
            .font(LumenFont.inter(15, .medium))
            .foregroundStyle(LumenColors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(cornerRadius: 999)
            .frame(maxWidth: 200, alignment: .trailing)
        }
    }

    /// Loading / failed / no guide, as one line above the grid.
    @ViewBuilder
    private func status(_ playlist: Playlist) -> some View {
        let line: (String, Bool)? = switch store.guideState(of: playlist) {
        case .idle, .loading: ("Loading the TV guide…", false)
        case .failed(let message): (message, true)
        case .unavailable: ("This playlist has no TV guide link.", false)
        case .loaded: nil
        }
        if let line {
            HStack(spacing: 10) {
                if !line.1 { ProgressView().tint(.white).controlSize(.small) }
                Text(line.0).font(LumenFont.caption).foregroundStyle(LumenColors.textSecondary).lineLimit(2)
                if line.1 {
                    Button("Try again") { Task { await store.loadGuide(playlist) } }
                        .font(LumenFont.inter(13, .semibold))
                        .foregroundStyle(LumenColors.textPrimary)
                }
            }
            .padding(.horizontal, wide ? 48 : 20)
            .padding(.bottom, 10)
        }
    }

    // MARK: Grid

    /// Two nested scroll views instead of one free 2-axis one: sideways outside (the times scroll
    /// with the programmes), up/down inside (the times stay on top). iOS gives each drag to one
    /// of them, so the grid moves in one direction at a time like a built-in list.
    /// Compose note: SwiftUI has no LazyColumn-in-LazyRow problem here; the inner LazyVStack
    /// stays lazy because the outer sideways scroll gives it a fixed height.
    private func grid(rows: [LiveChannel], guide: Guide?) -> some View {
        let totalWidth = CGFloat(hours * 60) * ppm
        let leading = (wide ? 48 : 20) + tileWidth + gap
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ruler(leading: leading, totalWidth: totalWidth)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.key) { channel in
                            row(channel, guide: guide, leading: leading, totalWidth: totalWidth)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            }
            .frame(width: leading + totalWidth, alignment: .leading)
            .overlay(alignment: .topLeading) { nowLine(leading: leading) }
            .clipped()
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.x + geo.contentInsets.leading
        } action: { _, x in
            // Not clamped: while the grid springs back at either end, the channel column and
            // its backdrop stay exactly where they are.
            scrollX = x
        }
    }

    /// Times along the top, every half hour. Rows scroll up under it.
    private func ruler(leading: CGFloat, totalWidth: CGFloat) -> some View {
        let slots = Int(hours * 2)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<slots, id: \.self) { i in
                let time = windowStart.addingTimeInterval(Double(i) * 1800)
                Text(rulerLabel(time, first: i == 0))
                    .font(LumenFont.inter(12, .medium))
                    .foregroundStyle(LumenColors.textSecondary)
                    .fixedSize()
                    .offset(x: leading + CGFloat(i * 30) * ppm)
            }
        }
        .frame(width: leading + totalWidth, height: 26, alignment: .topLeading)
        .mask(alignment: .topLeading) { visibleRightOfColumn(leading) }
    }

    /// A mask that hides what scrolls into the channel column (with a short fade), so the
    /// programmes and times disappear behind the tiles over the page's own background. A dark
    /// strip behind the column did the same but showed as a darker band (Hayat 2026-10-31).
    private func visibleRightOfColumn(_ leading: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leading - 4)
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 12)
            Color.black
        }
        .pinnedToLeadingEdge()
    }

    private func rulerLabel(_ time: Date, first: Bool) -> String {
        let hourMinute = time.formatted(date: .omitted, time: .shortened)
        // "8:00 PM" once, then "8:30", "9:00"…; the day at midnight.
        if Calendar.current.component(.hour, from: time) == 0, Calendar.current.component(.minute, from: time) == 0 {
            return time.formatted(.dateTime.weekday(.abbreviated))
        }
        if first { return hourMinute }
        return time.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }

    private func row(_ channel: LiveChannel, guide: Guide?, leading: CGFloat, totalWidth: CGFloat) -> some View {
        let from = Int64(windowStart.timeIntervalSince1970)
        let to = from + Int64(hours * 3600)
        let programmes = guide?.between(tvgId: channel.tvgId, from: from, to: to) ?? []
        let visibleLeft = leading + max(0, scrollX)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if programmes.isEmpty {
                    cell(title: guide == nil ? "" : "No guide info", time: nil, kind: .none,
                         x: leading, width: totalWidth, textShift: max(0, scrollX))
                }
                ForEach(programmes, id: \.start) { p in
                    let x = leading + CGFloat(Double(p.start - from) / 60) * ppm
                    let end = leading + CGFloat(Double(p.stop - from) / 60) * ppm
                    let left = max(x, leading)
                    let isSelected = selected == Selection(channelKey: channel.key, programmeStart: p.start)
                    let isNow = p.start <= Int64(now.timeIntervalSince1970) && Int64(now.timeIntervalSince1970) < p.stop
                    cell(title: p.title, time: p.startDate.formatted(date: .omitted, time: .shortened),
                         kind: isSelected ? .selected : (isNow ? .now : .normal),
                         x: left, width: end - left, textShift: max(0, visibleLeft - left))
                        // Double-tap watches; a single tap (after the double-tap window) selects.
                        .onTapGesture(count: 2) { play(channel, in: currentRows) }
                        .onTapGesture { selected = Selection(channelKey: channel.key, programmeStart: p.start) }
                }
            }
            .frame(width: leading + totalWidth, height: rowHeight, alignment: .topLeading)
            // The channel stays at the left edge; the programmes vanish as they scroll under it.
            .mask(alignment: .topLeading) { visibleRightOfColumn(leading) }
            Button { play(channel, in: currentRows) } label: {
                ChannelArt(logoUrl: channel.logoUrl, title: channel.title, cornerRadius: 9)
                    .frame(width: tileWidth, height: rowHeight - 12)
            }
            .buttonStyle(TileButtonStyle())
            .padding(.top, 6)
            .padding(.leading, wide ? 48 : 20)
            .pinnedToLeadingEdge()
            .accessibilityLabel("Watch \(channel.title)")
        }
        .frame(width: leading + totalWidth, height: rowHeight, alignment: .topLeading)
    }

    private enum CellKind { case normal, now, selected, none }

    private func cell(title: String, time: String?, kind: CellKind, x: CGFloat, width: CGFloat, textShift: CGFloat) -> some View {
        let w = max(0, width - 6)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(LumenFont.inter(wide ? 15 : 13, kind == .none ? .medium : .semibold))
                .foregroundStyle(kind == .selected ? LumenColors.background : (kind == .none ? LumenColors.textTertiary : LumenColors.textPrimary))
            if let time {
                Text(time)
                    .font(LumenFont.inter(11))
                    .foregroundStyle(kind == .selected ? Color(hex: 0x3A3A40) : LumenColors.textSecondary)
            }
        }
        .lineLimit(1)
        // Keeps the title readable when the programme began left of the screen.
        .offset(x: min(textShift, max(0, w - 60)))
        .padding(.horizontal, 10)
        .frame(width: w, height: rowHeight - 8, alignment: .leading)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(kind == .selected ? Color.white : (kind == .now ? LumenColors.glassStrong : (kind == .none ? Color.clear : LumenColors.glass)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind == .selected ? Color.clear : LumenColors.glassEdge, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .offset(x: x, y: 4)
    }

    /// The white line at now, from the ruler down; hidden behind the channel column.
    private func nowLine(leading: CGFloat) -> some View {
        let minutes = now.timeIntervalSince(windowStart) / 60
        let x = leading + CGFloat(minutes) * ppm
        return VStack(spacing: 0) {
            Circle().fill(.white).frame(width: 9, height: 9)
            Rectangle().fill(.white.opacity(0.85)).frame(width: 2)
        }
        .frame(width: 9)
        // Before the padding, so `geo` is the line itself: hidden once it reaches the channel column.
        .visualEffect { content, geo in
            content.opacity(geo.frame(in: .scrollView(axis: .horizontal)).minX < leading - 4 ? 0 : 1)
        }
        .padding(.leading, max(0, x - 4.5))
        .padding(.top, 20)
        .allowsHitTesting(false)
    }

    // MARK: iPad panel

    private func panel(rows: [LiveChannel], guide: Guide?) -> some View {
        let channel = selected.flatMap { s in rows.first { $0.key == s.channelKey } } ?? rows.first
        let programme = selected.flatMap { self.programme($0, guide) } ?? channel.flatMap { guide?.nowNext($0, at: now)?.now }
        return HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                if let channel {
                    Text([channel.title, programme?.timeRange, programme?.relative(to: now)].compactMap { $0 }.joined(separator: " · "))
                        .font(LumenFont.inter(15))
                        .foregroundStyle(LumenColors.textSecondary)
                        .lineLimit(1)
                    Text(programme?.title ?? channel.title)
                        .font(LumenFont.inter(34, .semibold))
                        .foregroundStyle(LumenColors.textPrimary)
                        .lineLimit(1)
                    if let description = programme?.description_ {
                        Text(description)
                            .font(LumenFont.inter(16))
                            .foregroundStyle(LumenColors.textPrimary.opacity(0.85))
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        Button { play(channel, in: rows) } label: { Label("Watch \(channel.title)", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                        dayChips
                    }
                } else {
                    Text("No channels here").font(LumenFont.title).foregroundStyle(LumenColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let channel {
                ZStack(alignment: .topLeading) {
                    ChannelArt(logoUrl: channel.logoUrl, title: channel.title, cornerRadius: 16)
                    PlayerLayerView(player: preview.player)
                        .opacity(preview.isBuffering ? 0 : 1)
                        .animation(.easeOut(duration: 0.3), value: preview.isBuffering)
                    HStack(spacing: 5) {
                        Circle().fill(LumenColors.accent).frame(width: 7, height: 7)
                        Text("LIVE").font(LumenFont.inter(12, .semibold)).foregroundStyle(LumenColors.accent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(10)
                }
                .frame(width: 300, height: 169)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { play(channel, in: rows) }
            }
        }
        .padding(22)
        .frame(height: 214)
        .glass(cornerRadius: 24)
    }

    // MARK: Actions

    /// The rows on screen now (for zapping in the player).
    private var currentRows: [LiveChannel] {
        guard let playlist = store.selected, case .loaded(let loaded) = store.state(of: playlist) else { return [] }
        let favourites = store.favourites(in: playlist)
        let current: Source? = source ?? (favourites.isEmpty ? store.visibleLiveCategories(loaded, in: playlist).first.map { Source.category($0.key) } : Source.favourites)
        switch current {
        case .favourites: return favourites
        case .category(let name): return loaded.channelsByCategory[name] ?? []
        case nil: return []
        }
    }

    private func play(_ channel: LiveChannel, in rows: [LiveChannel]) {
        guard let index = rows.firstIndex(where: { $0.key == channel.key }) else { return }
        previewTask?.cancel()
        preview.stop()
        playing = PlayerRoute(channels: rows, index: index)
    }

    private func programme(_ selection: Selection, _ guide: Guide?) -> Programme? {
        guard let start = selection.programmeStart, let playlist = store.selected,
              case .loaded(let loaded) = store.state(of: playlist),
              let channel = loaded.byKey[selection.channelKey] else { return nil }
        return guide?.schedule(tvgId: channel.tvgId).first { $0.start == start }
    }

    private func scroll(to date: Date) {
        let x = max(0, CGFloat(date.timeIntervalSince(windowStart) / 60) * ppm)
        withAnimation(.easeOut(duration: 0.35)) { position.scrollTo(x: x) }
    }

    /// iPad: the selected channel plays muted in the panel after 1.2 s (like the TV's preview).
    private func startPreview(_ channel: LiveChannel?) {
        previewTask?.cancel()
        guard let channel, playing == nil else { return }
        previewTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            preview.play(channel.streamUrl, debounce: false)
        }
    }

    private var tint: Color {
        guard let key = selected?.channelKey, let playlist = store.selected,
              case .loaded(let loaded) = store.state(of: playlist), let channel = loaded.byKey[key]
        else { return LumenColors.ambientCool }
        return NameTile.colour(for: channel.title)
    }

    private func title(_ source: Source?, _ loaded: LoadedLibrary) -> String {
        switch source {
        case .favourites: "Favourites"
        case .category(let name): store.liveCategoryTitle(name, in: store.selected, loaded: loaded) ?? name
        case nil: "Channels"
        }
    }

    static func halfHour(before date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 1800).rounded(.down) * 1800)
    }
}

/// iPhone: the tapped programme over the bottom of the grid. Double-tap in the grid to watch.
private struct DetailsCard: View {
    let channel: LiveChannel
    let programme: Programme?
    let now: Date
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(programme?.title ?? channel.title)
                    .font(LumenFont.inter(19, .semibold))
                    .foregroundStyle(LumenColors.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(channel.title).font(LumenFont.inter(14)).foregroundStyle(LumenColors.textSecondary).lineLimit(1)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LumenColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if let programme {
                Text("\(programme.timeRange) · \(programme.relative(to: now))")
                    .font(LumenFont.inter(14))
                    .foregroundStyle(LumenColors.textSecondary)
                if let description = programme.description_ {
                    Text(description)
                        .font(LumenFont.inter(15))
                        .foregroundStyle(LumenColors.textPrimary.opacity(0.85))
                        .lineLimit(3)
                }
            }
            Text("Double-tap a programme to watch")
                .font(LumenFont.caption)
                .foregroundStyle(LumenColors.textTertiary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Color(hex: 0x1E2028).opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private extension View {
    /// Keeps a view at the left edge of the visible grid while the programmes scroll sideways
    /// under it. Done in `visualEffect`, which runs as each frame is drawn (an offset from the
    /// scroll position in @State arrives a frame late). Never pushed left of the grid's own
    /// start: when you pull past the first half hour, the grid springs right and the channel
    /// column goes with it. Pinning it there too put it outside the grid, which cut the tiles off
    /// (Hayat's recording 2026-10-31).
    func pinnedToLeadingEdge() -> some View {
        visualEffect { content, geo in
            content.offset(x: max(0, -geo.frame(in: .scrollView(axis: .horizontal)).minX))
        }
    }
}
