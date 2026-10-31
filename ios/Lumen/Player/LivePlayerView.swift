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
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaylistStore.self) private var store

    init(channels: [LiveChannel], startIndex: Int) {
        self.channels = channels
        _index = State(initialValue: startIndex)
    }

    private var channel: LiveChannel { channels[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: model.player, onLayer: { pip.attach($0) }).ignoresSafeArea()

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
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleChrome() }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { drag in
                guard abs(drag.translation.height) > abs(drag.translation.width) else { return }
                // Swiping up moves to the next channel, as scrolling a list would.
                zap(by: drag.translation.height < 0 ? 1 : -1)
            }
        )
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.play(channel.streamUrl, debounce: false)
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
        }
        .onDisappear {
            pip.stop()
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
                    Spacer()
                    if pip.isPossible {
                        CircleGlassButton(systemImage: pip.isActive ? "pip.exit" : "pip.enter", label: "Picture in Picture",
                                          size: 44, fill: .black.opacity(0.35)) { pip.toggle() }
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
        if let now = store.guide(for: store.selected)?.nowNext(channel)?.now {
            return "\(now.title) · \(now.timeRange)"
        }
        return "\(index + 1) of \(channels.count)"
    }

    private func zap(by step: Int) {
        guard channels.count > 1 else { return }
        index = (index + step + channels.count) % channels.count
        model.play(channel.streamUrl, debounce: true)
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

    /// [muted]: the iPad guide's preview.
    init(muted: Bool = false) {
        player.isMuted = muted
        // Sound plays even with the silent switch on, as in other video apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.automaticallyWaitsToMinimizeStalling = true
        observation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                guard let self else { return }
                self.isBuffering = !playing && self.error == nil
            }
        }
    }

    func play(_ url: String, debounce: Bool) {
        pending?.cancel()
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
            let item = AVPlayerItem(url: parsed)
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
        player.pause()
        player.replaceCurrentItem(with: nil)
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
    /// Hands over the layer once (the live player builds Picture in Picture on it).
    var onLayer: ((AVPlayerLayer) -> Void)?

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        onLayer?(view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}
