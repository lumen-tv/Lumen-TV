import AVFoundation
import AVKit
import Shared
import SwiftUI

/// Full-screen live TV. Swipe up or down to change channel (like Up/Down on the TV remote),
/// tap to show or hide the channel name and buttons. Leaving the app (or the Picture in Picture
/// button) keeps the channel playing in a small window over other apps.
struct LivePlayerView: View {
    let channels: [LiveChannel]
    @State private var index: Int
    @State private var model = LivePlayerModel()
    @State private var pip = PictureInPicture()
    @State private var vlcPiP: VLCPiP?
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaylistStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad: the channel list down the left (swipe in from the left edge, or the list button).
    @State private var listOpen = false
    /// How far the list has been dragged (in from the edge, or back out) while a finger is down.
    @State private var listDrag: CGFloat = 0

    /// iPad only (Hayat 2026-11-02): an iPhone screen is too small to give a third of it to a list.
    private var listAllowed: Bool { UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular && channels.count > 1 }
    private static let listWidth: CGFloat = 380

    init(channels: [LiveChannel], startIndex: Int) {
        self.channels = channels
        _index = State(initialValue: startIndex)
    }

    private var channel: LiveChannel { channels[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: model.player, onLayer: { layer in
                model.layer = layer
                pip.attach(layer)
            }).ignoresSafeArea()
            // Always in place (VLC needs its view before it starts), shown only for VLC channels.
            // It ignores touches: they belong to the tap and swipe gestures.
            VLCVideo(engine: model.vlc, pip: $vlcPiP)
                .ignoresSafeArea()
                .opacity(model.usesVLC ? 1 : 0)

            if model.isBuffering {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let error = model.error {
                Text(error)
                    .font(LumenFont.body)
                    .foregroundStyle(LumenColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .glass(fill: Color.black.opacity(0.6))
                    .padding(32)
            }
            if chromeVisible { chrome.transition(.opacity) }
            if listAllowed { channelList }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if listOpen { closeList() } else { toggleChrome() }
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { drag in
                guard !listOpen, listDrag == 0, abs(drag.translation.height) > abs(drag.translation.width) else { return }
                // Swiping up moves to the next channel, as scrolling a list would.
                zap(by: drag.translation.height < 0 ? 1 : -1)
            }
        )
        .simultaneousGesture(listGesture)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.play(channel.streamUrl, debounce: false, is4K: channel.quality == "4K")
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
        }
        .onDisappear {
            pip.stop()
            vlcPiP?.stop()
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Like the TV's info overlay: close and AirPlay at the top; channel, LIVE and the hint over a
    /// dark fade at the bottom.
    private var chrome: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.75), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    CircleGlassButton(systemImage: "xmark", label: "Close", size: 44, fill: .black.opacity(0.35)) { dismiss() }
                    if listAllowed {
                        CircleGlassButton(systemImage: "list.bullet", label: "Channel list", size: 44, fill: .black.opacity(0.35)) {
                            openList()
                        }
                        .padding(.leading, 10)
                    }
                    Spacer()
                    if model.usesVLC, let vlcPiP {
                        CircleGlassButton(systemImage: vlcPiP.isActive ? "pip.exit" : "pip.enter", label: "Picture in Picture",
                                          size: 44, fill: .black.opacity(0.35)) { vlcPiP.toggle() }
                            .opacity(vlcPiP.isPossible ? 1 : 0.4)
                            .disabled(!vlcPiP.isPossible)
                            .padding(.trailing, 10)
                    } else if pip.isSupported && !model.usesVLC {
                        CircleGlassButton(systemImage: pip.isActive ? "pip.exit" : "pip.enter", label: "Picture in Picture",
                                          size: 44, fill: .black.opacity(0.35)) { pip.toggle() }
                            .opacity(pip.isPossible ? 1 : 0.4)
                            .disabled(!pip.isPossible)
                            .padding(.trailing, 10)
                    }
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                        .glass(cornerRadius: 22, fill: .black.opacity(0.35))
                }
                Spacer()
                HStack(spacing: 14) {
                    ChannelLogo(url: channel.logoUrl, title: channel.title, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(channel.title).font(LumenFont.inter(24, .semibold)).lineLimit(1)
                            if let quality = channel.quality { QualityTag(text: quality) }
                            HStack(spacing: 5) {
                                Circle().fill(LumenColors.accent).frame(width: 8, height: 8)
                                Text("LIVE").font(LumenFont.inter(13, .semibold)).foregroundStyle(LumenColors.accent)
                            }
                        }
                        Text(programmeLine)
                            .font(LumenFont.inter(15))
                            .foregroundStyle(LumenColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(LumenColors.textPrimary)
                Text(channels.count > 1 ? "Swipe up or down to change channel" : "Tap to hide")
                    .font(LumenFont.inter(14))
                    .foregroundStyle(LumenColors.textSecondary)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .accessibilityAction(named: "Next channel") { zap(by: 1) }
        .accessibilityAction(named: "Previous channel") { zap(by: -1) }
    }

    /// "EastEnders · 7:30 – 8:00 PM", or "3 of 12" without a guide.
    private var programmeLine: String {
        if let now = store.nowNext(channel)?.now {
            return "\(now.title) · \(now.timeRange)"
        }
        return "\(index + 1) of \(channels.count)"
    }

    // MARK: Channel list (iPad)

    /// Where the list sits: fully out (0), fully hidden (-width), or following the finger.
    private var listOffset: CGFloat {
        let width = Self.listWidth
        return listOpen ? min(0, max(-width, listDrag)) : min(0, -width + max(0, listDrag))
    }

    @ViewBuilder
    private var channelList: some View {
        // Always there, just off screen when closed, so it can slide out and back smoothly. Only
        // the offset changes while dragging: the list itself is `Equatable`, so its rows aren't
        // redrawn on every finger movement.
        ChannelListPanel(channels: channels, index: index, select: select)
            .equatable()
            .frame(width: Self.listWidth)
            .offset(x: listOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .allowsHitTesting(listOpen || listDrag != 0)
            .accessibilityHidden(!listOpen)
    }

    /// Starts within 30 pt of the left edge and moves sideways: pulls the list in. With the list
    /// out, a sideways drag to the left pushes it away.
    private var listGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { drag in
                guard listAllowed, abs(drag.translation.width) > abs(drag.translation.height) else { return }
                if listOpen {
                    listDrag = min(0, drag.translation.width)
                } else if drag.startLocation.x < 30 {
                    listDrag = max(0, drag.translation.width)
                }
            }
            .onEnded { drag in
                guard listAllowed, listDrag != 0 else { return }
                let projected = drag.predictedEndTranslation.width
                let open = listOpen ? !(listDrag < -Self.listWidth / 3 || projected < -200)
                                    : (listDrag > Self.listWidth / 3 || projected > 200)
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    listOpen = open
                    listDrag = 0
                }
                if open { withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false } }
            }
    }

    private func openList() {
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { listOpen = true }
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
    }

    private func closeList() {
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { listOpen = false }
    }

    /// A tap in the list: watch that channel (the list stays out, so you can keep looking).
    private func select(_ newIndex: Int) {
        guard newIndex != index else { return }
        Haptics.select()
        index = newIndex
        model.play(channel.streamUrl, debounce: false, is4K: channel.quality == "4K")
    }

    private func zap(by step: Int) {
        guard channels.count > 1 else { return }
        Haptics.select()
        index = (index + step + channels.count) % channels.count
        model.play(channel.streamUrl, debounce: true, is4K: channel.quality == "4K")
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = true }
        scheduleHide()
    }

    private func toggleChrome() {
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible.toggle() }
        if chromeVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = false }
        }
    }
}

/// Owns the AVPlayer. Like `PlayerHolder` on the TV: when zapping, the old stream stops at
/// once (providers often allow one connection) and the new one starts after 350 ms, so
/// flicking past several channels doesn't open each of them.
@MainActor
@Observable
final class LivePlayerModel {
    let player = AVPlayer()
    private(set) var isBuffering = true
    private(set) var error: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    /// Some channels (often the 4K ones) send HEVC video that Apple's player can't show: you get
    /// the sound over a black picture, and Picture in Picture never becomes possible. When the
    /// picture hasn't appeared 1.5 s after the sound started, the channel switches to VLC, which
    /// shows it (with VLC's own Picture in Picture).
    private(set) var usesVLC = false
    @ObservationIgnored private(set) lazy var vlc = VLCEngine()
    /// The full-screen player's video layer. Nil for the guide's muted preview, which never switches.
    @ObservationIgnored weak var layer: AVPlayerLayer?
    @ObservationIgnored private var videoCheck: Task<Void, Never>?
    @ObservationIgnored private var currentURL: URL?

    /// [muted]: the iPad guide's preview.
    init(muted: Bool = false) {
        player.isMuted = muted
        // Sound plays even with the silent switch on, as in other video apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        observation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                guard let self, !self.usesVLC else { return }
                self.isBuffering = !playing && self.error == nil
                if playing {
                    // Started: from now on a hiccup waits for enough buffer, rather than
                    // stuttering on and off.
                    self.player.automaticallyWaitsToMinimizeStalling = true
                    self.checkVideo()
                }
            }
        }
    }

    /// [is4K]: 4K channels go straight to VLC. They almost always send HEVC that Apple's player
    /// shows as a black picture, and waiting to find out would mean seconds of black.
    func play(_ url: String, debounce: Bool, is4K: Bool = false) {
        pending?.cancel()
        videoCheck?.cancel()
        videoCheck = nil
        currentURL = nil
        if usesVLC {
            vlc.stop()
            usesVLC = false
        }
        player.replaceCurrentItem(with: nil)
        error = nil
        isBuffering = true
        pending = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            guard let parsed = URL(string: url) else {
                error = "This channel's address can't be played."
                return
            }
            currentURL = parsed
            // 4K, or already known to need VLC: go straight there, no seconds of black.
            if layer != nil, is4K || Self.needsVLC.contains(Self.vlcKey(parsed)) {
                switchToVLC(parsed)
                return
            }
            let item = AVPlayerItem(url: parsed)
            // Start as soon as there's something to show (about a second, like the TV), instead
            // of Apple's default of waiting until it's sure it won't stall, which took seconds.
            item.preferredForwardBufferDuration = 2
            player.automaticallyWaitsToMinimizeStalling = false
            statusObservation = item.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    self?.error = "This channel isn't playing right now. Try another one."
                    self?.isBuffering = false
                }
            }
            player.replaceCurrentItem(with: item)
            player.play()
        }
    }

    func stop() {
        pending?.cancel()
        videoCheck?.cancel()
        videoCheck = nil
        if usesVLC {
            vlc.stop()
            usesVLC = false
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// Once per channel: 1.5 s after the sound starts, is there a picture?
    private func checkVideo() {
        guard videoCheck == nil, let layer, let url = currentURL else { return }
        videoCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.currentURL == url,
                  self.player.timeControlStatus == .playing, !layer.isReadyForDisplay else { return }
            self.switchToVLC(url)
        }
    }

    /// Channels that needed VLC, remembered so they open in it at once next time. Stored by
    /// server + stream file ("example.com/12345.m3u8"), never the full address (it holds the login).
    private static let vlcDefaultsKey = "liveNeedsVLC"
    private static var needsVLC: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: vlcDefaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: vlcDefaultsKey) }
    }
    private static func vlcKey(_ url: URL) -> String { "\(url.host ?? "")/\(url.lastPathComponent)" }

    private func switchToVLC(_ url: URL) {
        Self.needsVLC.insert(Self.vlcKey(url))
        usesVLC = true
        player.pause()
        player.replaceCurrentItem(with: nil)
        // Live: a short buffer (ms) keeps it close to live while riding out small hiccups.
        guard vlc.open(url, options: [":network-caching=1500", ":http-reconnect"]) else {
            error = "This channel's address can't be played."
            return
        }
        vlc.play()
        isBuffering = false
        error = nil
    }
}

/// Apple's AirPlay button (pick a TV or speaker), white to match the overlay.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Shows an AVPlayer through an AVPlayerLayer. (SwiftUI's VideoPlayer brings Apple's own
/// controls and gestures, which would fight the swipe-to-zap gesture.)
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Hands over the layer once it's on screen (the live player builds Picture in Picture on it).
    var onLayer: ((AVPlayerLayer) -> Void)?

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onWindow: ((AVPlayerLayer) -> Void)?

        // UIKit calls this when the view joins (or leaves) a window. SwiftUI's makeUIView runs
        // before that, while the view is still off screen, which is too early for PiP.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindow?(playerLayer) }
        }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.onWindow = onLayer
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}

/// iPad: the channels you're zapping through, down the left of the live player, with what's on
/// now. The playing one is white (the TV's focus look). Tap one to watch it.
struct ChannelListPanel: View, Equatable {
    let channels: [LiveChannel]
    let index: Int
    let select: (Int) -> Void
    @Environment(PlaylistStore.self) private var store

    /// Redrawn only when the playing channel changes, not while the panel is dragged.
    static func == (a: Self, b: Self) -> Bool { a.index == b.index && a.channels.count == b.channels.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text("Channels")
                        .font(LumenFont.inter(15, .semibold))
                        .foregroundStyle(LumenColors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    // Positions as ids (see `ChannelRows`).
                    ForEach(channels.indices, id: \.self) { i in
                        row(i).id(i)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(index, anchor: .center) }
            .onChange(of: index) { _, now in proxy.scrollTo(now, anchor: .center) }
        }
        // A tap on the list's empty space stays in the list (the video behind would close it).
        .contentShape(Rectangle())
        .onTapGesture {}
        // Flat dark glass: a live blur over moving video would cost every frame.
        .background(Color(hex: 0x0D0F14).opacity(0.86))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1) }
        .ignoresSafeArea()
    }

    private func row(_ i: Int) -> some View {
        let channel = channels[i]
        let on = i == index
        return Button { select(i) } label: {
            HStack(spacing: 12) {
                ChannelLogo(url: channel.logoUrl, title: channel.title, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.title).font(LumenFont.inter(16, .semibold)).lineLimit(1)
                    if let now = store.nowNext(channel)?.now {
                        Text(now.title).font(LumenFont.inter(13)).lineLimit(1)
                            .foregroundStyle(on ? LumenColors.background.opacity(0.7) : LumenColors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? LumenColors.background : LumenColors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(on ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
