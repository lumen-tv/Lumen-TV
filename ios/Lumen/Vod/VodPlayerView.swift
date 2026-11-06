import AVFoundation
import AVKit
import SwiftUI

/// Full-screen film/episode player. Films in formats Apple's player opens (.mp4, .m4v, .mov,
/// .m3u8) play through it, so they get Picture in Picture. For other Xtream films (most are .mkv,
/// often with DTS audio) the provider is first asked for an Apple-friendly .m3u8 copy of the same
/// film (`HLSRoute`); if it has one, Apple's player plays that. Everything else plays through VLC 4
/// (`VLCEngine`), which has its own Picture in Picture.
/// If Apple's player fails or shows no picture, the film moves to VLC at the same point.
/// Tap shows the controls; double-tap the left/right side skips 10 s back/forward.
/// In a series, "Skip intro" / "Skip recap" shows while that part plays and "Next episode" in the
/// end credits, from the intro databases (`SkipTimes`); nothing shows when they don't know the episode.
struct VodPlayerView: View {
    let playback: VodPlayback
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var systemDismiss
    /// Mac: the player sits in the window (`PlayerStage`), not in a cover iOS can dismiss.
    @Environment(\.closePlayer) private var closePlayer
    @State private var model = VodPlayerModel()
    /// Swipe down to close: how far the picture has been pulled down.
    @State private var pull: CGFloat = 0
    @State private var pip = PictureInPicture()
    @State private var vlcPiP: VLCPiP?
    @State private var current: VodPlayback
    @State private var queue: [VodPlayback]
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var skips: [SkipSegment] = []
    /// The segment whose pill was swiped away, so it stays away.
    @State private var skipDismissed: Double?
    /// The panel the Info / Continue Watching pills open over the bottom of the picture.
    @State private var panel: Panel?
    @State private var volume = SystemVolume()
    @Environment(\.lumenWide) private var wide

    enum Panel { case info, continueWatching }

    /// Double-tap jumps: which side (−1 back, 1 forward) and how far so far. Quick taps add up
    /// (10, 20, 30…), shown as a soft ripple on that side.
    @State private var tapJump: (side: Int, seconds: Int, at: Date)?
    @State private var nowPlaying: UUID?

    /// Swipes that start this close to the top of the screen belong to iOS, not the player.
    private static let systemEdge: CGFloat = 80

    init(playback: VodPlayback, playlist: Playlist) {
        self.playback = playback
        self.playlist = playlist
        _current = State(initialValue: playback)
        _queue = State(initialValue: playback.upNext)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Both stay in place; only the one playing shows. (VLC must have its view before it
            // starts, which matters when a film moves from Apple's player to VLC mid-way.)
            VLCVideo(engine: model.player, pip: $vlcPiP).ignoresSafeArea()
            PlayerLayerView(player: model.avPlayer, onLayer: { layer in
                model.layer = layer
                pip.attach(layer)
            })
            .ignoresSafeArea()
            .opacity(model.engine == .apple ? 1 : 0)

            #if os(macOS)
            // Mac: a click shows or hides the controls at once; a double click is full screen.
            MacClickSurface(
                click: { toggleControls() },
                doubleClick: { MacWindow.toggleFullScreen() },
                pinch: { amount in
                    if amount > 0.08, !model.fill { withAnimation(.easeOut(duration: 0.25)) { model.setFill(true) } }
                    if amount < -0.08, model.fill { withAnimation(.easeOut(duration: 0.25)) { model.setFill(false) } }
                }
            )
            .ignoresSafeArea()
            #else
            // Double-tap halves: back 10 s on the left, forward 10 s on the right; one tap toggles
            // the controls. (The double tap is declared first so a single tap waits for it.)
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { doubleTap(-1) }
                    .onTapGesture { toggleControls() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { doubleTap(1) }
                    .onTapGesture { toggleControls() }
            }
            // Pinch out to fill the screen (no black bars), in to fit, as in Apple's player.
            .simultaneousGesture(
                MagnifyGesture().onEnded { value in
                    if value.magnification > 1.08, !model.fill { withAnimation(.easeOut(duration: 0.25)) { model.setFill(true) } }
                    if value.magnification < 0.92, model.fill { withAnimation(.easeOut(duration: 0.25)) { model.setFill(false) } }
                }
            )
            #endif
            if let tapJump {
                JumpRipple(side: tapJump.side, seconds: tapJump.seconds)
                    .id(tapJump.at)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // Until the picture appears: the film's loading screen. Later (a jump, a hiccup) only
            // the thin line along the bottom, over the picture.
            if !model.started && !model.failed {
                PlaybackLoading(
                    art: current.art.flatMap(URL.init(string:)),
                    heading: current.heading.isEmpty ? current.title : current.heading,
                    detail: current.detail,
                    status: current.startAt > 30 ? "Resuming from \(formatTime(current.startAt))" : "Starting"
                )
                .transition(.opacity)
            } else if model.isBuffering && !model.failed {
                VStack {
                    Spacer()
                    LoadingLine().padding(.horizontal, 24).padding(.bottom, 12)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if model.failed {
                Text("This video can't be played right now.")
                    .font(LumenFont.body)
                    .padding(20)
                    .glass(fill: .black.opacity(0.6))
            }
            if controlsVisible, !LumenPlatform.playerIsMini { controls.transition(.opacity) }
            if !LumenPlatform.playerIsMini {
                SkipLayer(model: model, skips: skips, hasNext: !queue.isEmpty, scrubbing: scrubbing,
                          dismissed: $skipDismissed, controlsVisible: controlsVisible) { offer in
                    if let target = offer.target {
                        model.seek(to: target)
                    } else {
                        saveProgress(finished: true) // the credits count as watched
                        playNext()
                    }
                }
            }
        }
        // Swipe down to close, as in Apple's own players: the picture follows the finger, and
        // letting go far enough closes it (otherwise it springs back). Swipes starting along the
        // top edge are left to iOS (Control Center's brightness, notifications): those closed the
        // episode (Hayat 2026-11-03), so they're ignored, and a pull has to be longer too.
        .offset(y: pull)
        .scaleEffect(1 - min(pull, 400) / 2000)
        .simultaneousGesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global)
                .onChanged { drag in
                    guard scrubbing == nil, drag.startLocation.y > Self.systemEdge, drag.translation.height > 0,
                          drag.translation.height > abs(drag.translation.width) * 2 else { return }
                    pull = drag.translation.height
                }
                .onEnded { drag in
                    if pull > 220 || (pull > 100 && drag.predictedEndTranslation.height > 600) {
                        dismiss()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { pull = 0 }
                    }
                }
        )
        // Mac: the keyboard (Space pause, ← → 10 s, Esc close, F full screen) and the mouse.
        .macPlayerKeys { key in
            switch key {
            case .space: model.togglePause(); showControls()
            case .left: model.skip(-10); showControls()
            case .right: model.skip(10); showControls()
            case .escape: if panel != nil { panel = nil } else { dismiss() }
            case .up, .down: return false
            }
            return true
        }
        .macMouseMoved { showControls() }
        #if os(macOS)
        // Two fingers: sideways seeks (one jump when they lift), up and down is the volume.
        .macPlayerScroll(
            blocked: { panel != nil },
            seek: { showSwipe($0) },
            seekEnded: { finishSwipe($0) },
            volume: { volume.set(volume.level + $0); showControls() }
        )
        .macPlayback(refresh: queue.count) {
            MacPlaybackActions(
                isPlaying: { model.isPlaying },
                togglePause: { model.togglePause(); showControls() },
                back: { model.skip(-10); showControls() },
                forward: { model.skip(10); showControls() },
                nextEpisode: queue.isEmpty ? nil : { saveProgress(); playNext() },
                audioTracks: { model.audioTracks() },
                subtitleTracks: { model.subtitleTracks() },
                selectAudio: { model.selectAudio($0) },
                selectSubtitle: { model.selectSubtitle($0) }
            )
        }
        #endif
        .landscapeVideo()
        .hideStatusBar(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.start(current.streamUrl, at: current.startAt, expectedLength: current.progress.duration)
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
            showNowPlaying()
        }
        .onChange(of: current.id) { _, _ in showNowPlaying() }
        // The lock screen's timeline runs by itself from the rate; it's set again on play/pause,
        // jumps and every few seconds so it never drifts.
        .onChange(of: model.isPlaying) { _, _ in updateNowPlaying() }
        .onChange(of: model.duration) { _, _ in updateNowPlaying() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                updateNowPlaying()
            }
        }
        .onDisappear {
            if let nowPlaying { NowPlaying.shared.end(nowPlaying) }
            saveProgress()
            pip.stop()
            vlcPiP?.stop()
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // Save every 15 s while playing, as on the TV.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if model.isPlaying { saveProgress(quietly: true) }
            }
        }
        .onChange(of: model.ended) { _, ended in
            guard ended else { return }
            saveProgress(finished: true)
            if queue.isEmpty { dismiss() } else { playNext() }
        }
        // Where this episode's intro, recap and credits are; playback doesn't wait for it.
        .task(id: current.id) {
            skips = []
            skipDismissed = nil
            guard let ref = current.skipRef else { return }
            skips = await SkipTimes.shared.segments(for: ref)
        }
    }

    /// Laid out like Apple's own player (Hayat 2026-11-03), without its Share and Extras: close
    /// and Picture in Picture · AirPlay top left, volume top right, −10 / play / +10 in the middle,
    /// then the title with speed · audio · subtitles, the timeline, and Info / Continue Watching.
    private var controls: some View {
        ZStack {
            // Apple dims the picture while its controls show. Taps go through to the halves below.
            Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    PlayerCircleButton(systemImage: "xmark", label: "Close") { dismiss() }
                    #if os(macOS)
                    // Mac: full screen and back (also F, or the window's green button).
                    PlayerCircleButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Full screen") {
                        MacWindow.toggleFullScreen()
                    }
                    PlayerCircleButton(systemImage: "pip", label: "Mini player") {
                        PlayerStage.shared.toggleMini()
                    }
                    #endif
                    PlayerCapsule {
                        pipButton
                        AirPlayButton().frame(width: 52, height: 44).accessibilityLabel("AirPlay")
                    }
                    Spacer(minLength: 12)
                    VolumeCapsule(volume: volume, width: wide ? 190 : 150, touched: showControls)
                }

                Spacer(minLength: 12)

                HStack(spacing: wide ? 110 : 64) {
                    PlayerCircleButton(systemImage: "gobackward.10", label: "Back 10 seconds", size: 72, iconSize: 30) {
                        model.skip(-10); showControls()
                    }
                    PlayerCircleButton(systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                                       label: model.isPlaying ? "Pause" : "Play", size: 104, iconSize: 44) {
                        model.togglePause(); showControls()
                    }
                    PlayerCircleButton(systemImage: "goforward.10", label: "Forward 10 seconds", size: 72, iconSize: 30) {
                        model.skip(10); showControls()
                    }
                }

                Spacer(minLength: 12)

                if let panel {
                    panelView(panel)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            if !current.heading.isEmpty, let detail = current.detail {
                                Text(detail)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                            Text(current.heading.isEmpty ? current.title : current.heading)
                                .font(.system(size: wide ? 28 : 24, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        PlayerCapsule {
                            SpeedMenu(model: model)
                            AudioMenu(model: model)
                            SubtitleMenu(model: model)
                        }
                    }
                    .padding(.bottom, 10)
                    PlayerTimeline(model: model, scrubbing: $scrubbing, touched: showControls)
                }

                HStack(spacing: 12) {
                    PlayerPill(title: "Info", selected: panel == .info) { toggle(.info) }
                    PlayerPill(title: "Continue Watching", selected: panel == .continueWatching) { toggle(.continueWatching) }
                    if !queue.isEmpty {
                        PlayerPill(title: "Next Episode") {
                            saveProgress()
                            playNext()
                        }
                    }
                    Spacer()
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, wide ? 32 : 20)
            .padding(.vertical, wide ? 20 : 14)
            // Mac: below the window's close / minimise / full screen buttons.
            .padding(.top, LumenPlatform.isMac ? 28 : 0)
            .animation(.easeOut(duration: 0.22), value: panel)
        }
        .background(HiddenVolumeView(volume: volume).frame(width: 1, height: 1))
    }

    @ViewBuilder
    private var pipButton: some View {
        if model.engine == .vlc, let vlcPiP, !LumenPlatform.isMac || vlcPiP.isPossible {
            Button { vlcPiP.toggle() } label: {
                PlayerIcon(systemImage: vlcPiP.isActive ? "pip.exit" : "pip.enter")
            }
            .buttonStyle(.plain)
            .disabled(!vlcPiP.isPossible)
            .opacity(vlcPiP.isPossible ? 1 : 0.4)
            .accessibilityLabel("Picture in Picture")
        } else if model.engine == .apple && pip.isSupported {
            Button { pip.toggle() } label: {
                PlayerIcon(systemImage: pip.isActive ? "pip.exit" : "pip.enter")
            }
            .buttonStyle(.plain)
            .disabled(!pip.isPossible)
            .opacity(pip.isPossible ? 1 : 0.4)
            .accessibilityLabel("Picture in Picture")
        }
    }

    private func doubleTap(_ side: Int) {
        let adding = tapJump.map { $0.side == side && Date.now.timeIntervalSince($0.at) < 1.2 } ?? false
        let seconds = adding ? (tapJump?.seconds ?? 0) + 10 : 10
        let now = Date.now
        withAnimation(.easeOut(duration: 0.15)) { tapJump = (side, seconds, now) }
        model.skip(Int32(side * 10))
        Haptics.select()
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard tapJump?.at == now else { return }
            withAnimation(.easeOut(duration: 0.3)) { tapJump = nil }
        }
        updateNowPlaying()
    }

    #if os(macOS)
    /// Seconds for a two-finger swipe of that many points, in 5 s steps (a long swipe is minutes).
    private func swipeSeconds(_ points: CGFloat) -> Int { Int((points * 0.5 / 5).rounded()) * 5 }

    private func showSwipe(_ points: CGFloat) {
        let seconds = swipeSeconds(points)
        guard seconds != 0 else { tapJump = nil; return }
        // The same date while the fingers are down, so the ripple's number changes in place.
        withAnimation(.easeOut(duration: 0.15)) { tapJump = (seconds > 0 ? 1 : -1, abs(seconds), tapJump?.at ?? .now) }
        showControls()
    }

    private func finishSwipe(_ points: CGFloat) {
        let seconds = swipeSeconds(points)
        guard seconds != 0 else { tapJump = nil; return }
        model.skip(Int32(seconds))
        showControls()
        updateNowPlaying()
        let at = tapJump?.at
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard tapJump?.at == at else { return }
            withAnimation(.easeOut(duration: 0.3)) { tapJump = nil }
        }
    }
    #endif

    private func showNowPlaying() {
        let token = NowPlaying.shared.begin(
            title: current.heading.isEmpty ? current.title : current.heading,
            subtitle: current.detail,
            artwork: current.art.flatMap(URL.init(string:)),
            live: false,
            controls: .init(
                togglePause: { model.togglePause() },
                play: { if !model.isPlaying { model.togglePause() } },
                pause: { if model.isPlaying { model.togglePause() } },
                skip: { model.skip(Int32($0)) },
                seek: { model.seek(to: $0) }
            )
        )
        nowPlaying = token
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let nowPlaying else { return }
        NowPlaying.shared.update(nowPlaying, position: model.position, duration: model.duration,
                                 playing: model.isPlaying, rate: model.rate)
    }

    private func toggle(_ which: Panel) {
        panel = panel == which ? nil : which
        showControls()
    }

    @ViewBuilder
    private func panelView(_ which: Panel) -> some View {
        switch which {
        case .info:
            VStack(alignment: .leading, spacing: 8) {
                Text(current.heading.isEmpty ? current.title : current.heading)
                    .font(.system(size: wide ? 26 : 22, weight: .bold))
                if let detail = current.detail {
                    Text(detail).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
                Text(current.plot ?? "No description for this one.")
                    .font(.system(size: wide ? 17 : 15))
                    .foregroundStyle(.white.opacity(current.plot == nil ? 0.6 : 0.9))
                    .lineLimit(wide ? 5 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: wide ? 760 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .continueWatching:
            let items = otherUnfinished
            if items.isEmpty {
                Text("Nothing else to continue yet.")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items, id: \.key) { item in
                            Button { Task { await switchTo(item) } } label: {
                                let upNext = item.finished ? item.next : nil
                                WideCard(url: item.posterUrl, title: upNext ?? item.title,
                                         progress: upNext == nil ? item.fraction : nil, width: wide ? 260 : 200)
                            }
                            .buttonStyle(TileButtonStyle())
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Films and series in progress, newest first, apart from what's playing.
    private var otherUnfinished: [WatchProgress] {
        (store.continueWatching(.movie, in: playlist) + store.continueWatching(.series, in: playlist))
            .filter { $0.key != current.progress.key && $0.seriesId.map { $0 != current.progress.seriesId } ?? true }
            .sorted { $0.updated > $1.updated }
    }

    /// Plays a Continue Watching card here, without leaving the player: a film where it stopped;
    /// an episode where it stopped, or the next one when that was finished.
    private func switchTo(_ item: WatchProgress) async {
        if let next = await resumePlayback(item, store: store, playlist: playlist) { open(next) }
    }

    private func open(_ next: VodPlayback) {
        saveProgress()
        current = next
        queue = next.upNext
        panel = nil
        model.start(next.streamUrl, at: next.startAt, expectedLength: next.progress.duration)
        showControls()
    }

    private func playNext() {
        guard let next = queue.first else { return }
        queue.removeFirst()
        current = next
        model.start(next.streamUrl, at: 0, expectedLength: next.progress.duration)
        showControls()
    }

    private func saveProgress(finished: Bool = false, quietly: Bool = false) {
        var item = current.progress
        let duration = model.duration > 0 ? model.duration : item.duration
        guard duration > 0 || model.position > 0 else { return }
        item.duration = duration
        item.position = finished ? duration : model.position
        item.updated = .now
        if item.kind == .series { item.next = queue.first?.progress.title }
        store.saveProgress(item, in: playlist, quietly: quietly)
    }

    private func dismiss() {
        if let closePlayer { closePlayer() } else { systemDismiss() }
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { panel = nil }
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying, scrubbing == nil, panel == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// "Skip intro" / "Skip recap" / "Next episode": a white pill like the TV's, bottom right. Tap
/// skips; swipe it away to hide it. Its own view for the same reason as `PlayerTimeline`.
struct SkipLayer: View {
    let model: VodPlayerModel
    let skips: [SkipSegment]
    let hasNext: Bool
    let scrubbing: Double?
    @Binding var dismissed: Double?
    let controlsVisible: Bool
    let action: (SkipOffer) -> Void

    var body: some View {
        ZStack {
            if let offer {
                Button { action(offer) } label: {
                    Label(offer.label, systemImage: "forward.end.fill")
                        .font(LumenFont.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { _ in dismissed = offer.segmentStart })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 24)
                // Above the bottom panel when the controls are up.
                .padding(.bottom, controlsVisible ? 210 : 32)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: offer)
    }

    private var offer: SkipOffer? {
        guard !model.failed, scrubbing == nil, !skips.isEmpty,
              let offer = SkipPick.at(skips, position: model.position, duration: model.duration, hasNext: hasNext),
              offer.segmentStart != dismissed else { return nil }
        return offer
    }
}

struct Track {
    let id: Int32
    let name: String
    let selected: Bool
}

/// Wraps Apple's player and VLC (see `VodPlayerView`). Their state is read twice a second (simpler
/// and sturdier than delegate callbacks) and published to SwiftUI.
@MainActor
@Observable
final class VodPlayerModel {
    enum Engine { case apple, vlc }

    @ObservationIgnored let player = VLCEngine()
    @ObservationIgnored let avPlayer = AVPlayer()
    /// Apple's video layer, to tell "sound but no picture" (e.g. HEVC it can't show).
    @ObservationIgnored weak var layer: AVPlayerLayer?
    private(set) var engine: Engine = .vlc
    /// The film's own link (VLC plays this) and what Apple's player plays: the same link, or the
    /// provider's .m3u8 copy of it.
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var appleURL: URL?
    /// Each `start` gets a new one, so an .m3u8 check that answers late doesn't start an old film.
    @ObservationIgnored private var startToken = UUID()
    /// Why the .m3u8 copy was given up on, for Settings.
    @ObservationIgnored private var copyProblem: String?
    /// Apple's player: where to start once the film is ready, and whether it has started.
    @ObservationIgnored private var appleStartAt: Double = 0
    @ObservationIgnored private var appleStarted = false
    @ObservationIgnored private var applePlayingSince: Date?
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var failed = false
    private(set) var ended = false
    @ObservationIgnored private var timer: Timer?
    /// After a jump, the players report the old time for a moment; the bar holds the target
    /// until they catch up, instead of snapping back and forth.
    @ObservationIgnored private var seekHold: (target: Double, until: Date)?
    /// Dragging the bar: the last live jump (VLC), and Apple's jump in flight plus the next one.
    @ObservationIgnored private var lastScrubJump = Date.distantPast
    @ObservationIgnored private var appleSeeking = false
    @ObservationIgnored private var appleScrubNext: Double?
    /// A jump asked for before VLC can jump (just after opening): done once it's playing.
    @ObservationIgnored private var pendingVLCJump: Double?
    /// Stall watchdog (`checkStall`): you didn't pause, yet the picture hasn't moved for a while.
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var lastTime: Double = -1
    @ObservationIgnored private var lastAdvance = Date()
    @ObservationIgnored private var recoveries: [Date] = []
    /// Reconnect guards (VLC): the provider sometimes drops the connection mid-film, and after a
    /// reconnect VLC can lose track: its clock restarts near 0:00 or freezes, or its length shrinks
    /// to about where you are (the bar then sits at the end and Next episode appears). These keep
    /// the film's length once it has played and when `position` was last confirmed; a time that
    /// disagrees for a few seconds reopens the film cleanly at `position` (`checkVLC`).
    @ObservationIgnored private var knownLength: Double = 0
    @ObservationIgnored private var lengthLocked = false
    @ObservationIgnored private var goodAt = Date()
    @ObservationIgnored private var badSince: Date?
    /// Where the last reopen started, so an end that comes again from the same point is believed.
    @ObservationIgnored private var lastRecoverAt: Double?
    /// The provider's length for this film or episode (0 = unknown). VLC estimates the length from
    /// what the server sends, and after a resume (opened part-way in) that estimate was sometimes
    /// far off; when the two disagree a lot, the provider's is used (`trustedLength`).
    @ObservationIgnored private var expectedLength: Double = 0
    /// Whether a bad time has already been answered with a jump since this open (`checkVLC`).
    @ObservationIgnored private var triedJumpFix = false
    /// Whether the picture has moved since this film was opened (or reopened).
    @ObservationIgnored private var hasPlayed = false
    /// The picture has appeared (it moved while playing): the loading screen goes.
    private(set) var started = false
    /// Whether the remembered audio/subtitle language has been picked for this film yet.
    @ObservationIgnored private var appliedPreferences = false
    /// Playback speed (1 = normal), kept for the next episode. VLC starts each film at 1, so it's
    /// set again once the film plays (`vlcRate` = what VLC was last given).
    private(set) var rate: Float = 1
    @ObservationIgnored private var vlcRate: Float = 1

    /// Pinch to fill (`true`) or fit, kept for the next film.
    private(set) var fill = false

    func setFill(_ value: Bool) {
        fill = value
        layer?.videoGravity = value ? .resizeAspectFill : .resizeAspect
        player.setFill(value)
    }

    func setRate(_ value: Float) {
        rate = value
        avPlayer.defaultRate = value // what play() uses
        if avPlayer.rate > 0 { avPlayer.rate = value }
        if engine == .vlc {
            player.setRate(value)
            vlcRate = value
        }
    }

    init() {
        try? AVAudioSessionHelper.activate()
    }

    /// Containers Apple's player opens. Everything else goes straight to VLC.
    static func prefersApple(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "m3u8"].contains(url.pathExtension.lowercased())
    }

    func start(_ url: String, at seconds: Double, expectedLength: Double = 0) {
        PlayerLog.add("start at \(PlayerLog.t(seconds)) expected \(PlayerLog.t(expectedLength))")
        self.expectedLength = expectedLength
        player.stop()
        avPlayer.replaceCurrentItem(with: nil)
        guard let parsed = URL(string: url) else { failed = true; return }
        self.url = parsed
        appleURL = nil
        pendingVLCJump = nil
        seekHold = nil
        recoveries = []
        knownLength = 0
        lengthLocked = false
        lastRecoverAt = nil
        let token = UUID()
        startToken = token
        if Self.prefersApple(parsed) {
            startApple(parsed, at: seconds)
            return
        }
        guard let copy = HLSRoute.candidate(for: parsed) else {
            startVLC(parsed, at: seconds)
            return
        }
        switch HLSRoute.known(for: parsed) {
        case .some(true):
            startApple(copy, at: seconds)
        case .some(false):
            startVLC(parsed, at: seconds)
        case .none:
            // First film from this provider: ask whether it has the .m3u8 copy (a few seconds at
            // most), and remember the answer so later films start straight away.
            isBuffering = true
            failed = false
            position = seconds
            Task { [weak self] in
                let problem = await HLSRoute.probe(copy)
                guard let self, self.startToken == token else { return }
                if let problem {
                    HLSRoute.remember(false, for: parsed, reason: problem)
                    self.startVLC(parsed, at: seconds)
                } else {
                    self.startApple(copy, at: seconds)
                }
            }
        }
    }

    /// Whether Apple's player is playing the provider's .m3u8 copy (not the film's own file).
    private var playingCopy: Bool { appleURL != nil && appleURL != url }

    private func resetState(at seconds: Double) {
        position = seconds
        duration = knownLength // 0 for a new film; the same film reopened keeps its length
        failed = false
        ended = false
        isBuffering = true
        appliedPreferences = false
        vlcRate = 1
        player.setFill(fill)
        layer?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        userPaused = false
        lastTime = -1
        lastAdvance = .now
        goodAt = .now
        badSince = nil
        hasPlayed = false
        set(\.started, false)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func startApple(_ url: URL, at seconds: Double) {
        PlayerLog.add("apple open \(url.pathExtension) at \(PlayerLog.t(seconds))")
        engine = .apple
        appleURL = url
        appleStartAt = seconds
        appleStarted = false
        applePlayingSince = nil
        avPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        resetState(at: seconds)
    }

    /// Apple's player couldn't (fail, or no picture): carry on in VLC from the same point.
    private func moveToVLC() {
        guard let url else { return }
        // The .m3u8 copy didn't play: this provider's copies aren't usable, so later films skip them.
        // (One film failing on a provider whose copies have played before doesn't count.)
        if playingCopy, HLSRoute.known(for: url) != true {
            HLSRoute.remember(false, for: url, reason: copyProblem ?? "Apple's player couldn't play it")
        }
        copyProblem = nil
        appleURL = nil
        let at = max(position, appleStartAt)
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        startVLC(url, at: at)
    }

    private func startVLC(_ parsed: URL, at seconds: Double) {
        engine = .vlc
        var options = [
            // A network buffer (ms) to ride out slow provider servers. It's also how long a film
            // takes to start (and to resume after a jump): 3 s felt slow, 1.5 s rides out hiccups.
            ":network-caching=1500",
            // No ":http-reconnect": VLC's own reconnect asks for "the rest from byte X", which
            // Xtream servers often answer badly, and VLC then lost its place (time back to 0:00 or
            // at the end, Next episode showing mid-film). A dropped connection now ends or fails
            // the film in VLC, and `poll` reopens it here at the last good time instead.
        ]
        if seconds > 1 { options.append(":start-time=\(Int(seconds))") }
        PlayerLog.add("vlc open \(parsed.pathExtension) at \(PlayerLog.t(seconds))")
        triedJumpFix = false
        guard player.open(parsed, options: options) else { failed = true; return }
        resetState(at: seconds)
        player.play()
    }

    // Each value is only set when it changes: setting an @Observable property redraws whatever
    // reads it even when the value is the same, which redrew the player twice a second.

    private func update(position time: Double) {
        guard time > 0 else { return }
        if let hold = seekHold {
            if abs(time - hold.target) > 3, Date.now < hold.until { return }
            seekHold = nil
        }
        if abs(time - position) >= 0.25 { position = time }
        goodAt = .now
    }

    private func set<T: Equatable>(_ path: ReferenceWritableKeyPath<VodPlayerModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func poll() {
        if engine == .apple { pollApple(); return }
        let time = player.time
        PlayerLog.add("vlc t \(PlayerLog.t(time)) len \(PlayerLog.t(player.length)) \(player.state) seek \(player.isSeekable) | pos \(PlayerLog.t(position)) dur \(PlayerLog.t(duration)) known \(PlayerLog.t(knownLength))\(lengthLocked ? " locked" : "")\(seekHold != nil ? " hold" : "")\(pendingVLCJump != nil ? " pending" : "")\(hasPlayed ? "" : " opening")")
        if let target = pendingVLCJump, player.isPlaying, player.isSeekable {
            pendingVLCJump = nil
            player.jump(to: target)
        }
        if !checkVLC(time) { return }
        checkStall(time)
        update(position: time)
        if knownLength > 0 { set(\.duration, knownLength) }
        set(\.isPlaying, player.isPlaying)
        if player.isPlaying, vlcRate != rate {
            player.setRate(rate)
            vlcRate = rate
        }
        // Audio lists only exist with 2+ tracks, so also go when there are subtitles ("Off" is
        // always listed): films with one audio track never got the remembered subtitles.
        if !appliedPreferences, player.isPlaying, !audioTracks().isEmpty || subtitleTracks().count > 1 {
            appliedPreferences = true
            applyPreferences()
        }
        switch player.state {
        case .error:
            // Opening failed (usually the provider still counting the last connection), or the
            // connection dropped mid-film. Reopen at the same point by itself (what reopening by
            // hand did); `recover` says it can't be played after 3 tries in 2 minutes.
            if !failed { recover(at: max(position, pendingVLCJump ?? 0), why: "error") }
        case .ended:
            // A dropped connection looks like the end of the file to VLC. Only believe it near the
            // real end; otherwise reopen where you were (unless it ended there again right after a
            // reopen: then the file really is shorter than VLC thought).
            if knownLength > 0, position < knownLength - SkipPick.creditsLatest,
               abs(position - (lastRecoverAt ?? -100)) > 5 {
                recover(at: position, why: "early end")
            } else {
                if !ended { PlayerLog.add("ended at \(PlayerLog.t(position))") }
                set(\.ended, true)
            }
        case .opening: set(\.isBuffering, !player.isPlaying)
        default: set(\.isBuffering, false)
        }
    }

    private func pollApple() {
        guard let item = avPlayer.currentItem else { return }
        switch item.status {
        case .failed:
            moveToVLC()
            return
        case .readyToPlay where !appleStarted:
            // A copy made on the fly can come without a length (it grows as it's made), and then
            // jumping doesn't work: VLC plays the real file instead.
            if playingCopy, !item.duration.seconds.isFinite {
                copyProblem = "Stream has no length, so no jumping"
                moveToVLC()
                return
            }
            appleStarted = true
            if appleStartAt > 1 {
                avPlayer.seek(to: CMTime(seconds: appleStartAt, preferredTimescale: 600))
            }
            avPlayer.play()
        default: break
        }
        let time = avPlayer.currentTime().seconds
        if time.isFinite {
            checkStall(time)
            update(position: time)
        }
        let length = item.duration.seconds
        if length.isFinite, length > 0 { set(\.duration, length) }
        let status = avPlayer.timeControlStatus
        set(\.isPlaying, status == .playing)
        set(\.isBuffering, !appleStarted || status == .waitingToPlayAtSpecifiedRate)
        if isPlaying {
            let since = applePlayingSince ?? .now
            applePlayingSince = since
            if playingCopy, layer?.isReadyForDisplay == true, let url, HLSRoute.known(for: url) != true {
                HLSRoute.remember(true, for: url, reason: "Plays in Apple's player") // picture and sound: they work
            }
            // Sound for 2 s but still no picture: Apple's player can't show this video.
            if let layer, !layer.isReadyForDisplay, Date.now.timeIntervalSince(since) > 2 {
                copyProblem = "Sound but no picture"
                moveToVLC()
                return
            }
        }
        if !appliedPreferences, appleStarted, !audioTracks().isEmpty || !subtitleTracks().isEmpty {
            appliedPreferences = true
            applyPreferences()
        }
        if appleStarted, duration > 0, position >= duration - 1, status == .paused, !ended, !appleSeeking { ended = true }
    }

    func togglePause() {
        userPaused = isPlaying
        if engine == .apple {
            if avPlayer.rate > 0 { avPlayer.pause() } else { avPlayer.play() }
            isPlaying.toggle()
            return
        }
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func skip(_ seconds: Int32) {
        if engine == .apple {
            seek(to: max(0, position + Double(seconds)))
            return
        }
        seek(to: max(0, position + Double(seconds)))
    }

    /// Lands exactly on `seconds` (letting go of the bar, a skip button).
    func seek(to seconds: Double) {
        PlayerLog.add("seek to \(PlayerLog.t(seconds))")
        appleScrubNext = nil
        if engine == .apple {
            if appleStarted {
                avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                appleStartAt = seconds // not open yet: it starts there instead
            }
        } else if player.isPlaying, player.isSeekable {
            player.jump(to: seconds)
        } else {
            // Jumping while VLC is still opening the film could leave it stuck for good (you had to
            // close and reopen it): the jump waits until the film is actually playing.
            pendingVLCJump = seconds
        }
        hold(seconds)
        lastAdvance = .now
    }

    /// While the bar is dragged: shows the picture near that point, at most a few times a second.
    /// Apple's player jumps to the nearest keyframe (fast) and only one jump runs at a time; the
    /// newest position waits for it, so the picture keeps up without a queue of old jumps.
    func scrub(to seconds: Double) {
        if engine == .apple {
            guard !appleSeeking else { appleScrubNext = seconds; return }
            appleSeeking = true
            let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
            avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.appleSeeking = false
                    if let next = self.appleScrubNext {
                        self.appleScrubNext = nil
                        self.scrub(to: next)
                    }
                }
            }
            return
        }
        guard player.isPlaying, player.isSeekable, Date.now.timeIntervalSince(lastScrubJump) > 0.25 else { return }
        lastScrubJump = .now
        player.jump(to: seconds, fast: true)
    }

    /// Reconnect guard for VLC (see `knownLength`). The length is kept once the film has played:
    /// a later, different length from VLC is ignored (the bar and Next episode use the kept one).
    /// Returns false when this time is not to be believed: it jumped although you didn't skip or
    /// drag (back towards 0:00, or ahead faster than playing could go). Such readings aren't shown;
    /// if they last 3 s (8 s while the film is still opening), it's reopened at the last good time.
    private func checkVLC(_ time: Double) -> Bool {
        let length = trustedLength(player.length)
        if length > 0, !lengthLocked { knownLength = length }
        if hasPlayed, knownLength > 0 { lengthLocked = true }

        let userJumping = seekHold != nil || pendingVLCJump != nil || Date.now.timeIntervalSince(lastScrubJump) < 2
        let hasTime = time > 0 || (player.isPlaying && position > 10)
        let ahead = time - position
        let allowed = Date.now.timeIntervalSince(goodAt) * Double(max(rate, 1)) + 10
        guard hasTime, !userJumping, ahead < -10 || ahead > allowed else {
            badSince = nil
            return true
        }
        let since = badSince ?? .now
        if badSince == nil { PlayerLog.add("bad time \(PlayerLog.t(time)), expected about \(PlayerLog.t(position))") }
        badSince = since
        let waited = Date.now.timeIntervalSince(since)
        // First a jump back to the right point, which is quicker than reopening (a resume that
        // VLC started from the beginning plays on fine once it has jumped); then a reopen.
        if waited > 1.5, !triedJumpFix, player.isPlaying, player.isSeekable {
            triedJumpFix = true
            PlayerLog.add("jump fix to \(PlayerLog.t(position))")
            player.jump(to: position)
            hold(position)
            badSince = nil
        } else if waited > (hasPlayed ? 3 : 8) {
            recover(at: position, why: "bad time")
        }
        return false
    }

    /// VLC's length, unless the provider's length for this item is known and differs a lot (more
    /// than 2 minutes and 10%): then the provider's. With no length from VLC yet, the provider's.
    private func trustedLength(_ vlc: Double) -> Double {
        guard expectedLength > 60 else { return vlc }
        if vlc <= 0 { return expectedLength }
        return abs(vlc - expectedLength) > max(120, expectedLength * 0.1) ? expectedLength : vlc
    }

    /// Some provider servers stop answering after a jump (they allow one connection, and the
    /// jump opens a new one before the old one closes), which left the film frozen until it was
    /// reopened. When the picture hasn't moved for 15 s without you pausing (7 s while it's still
    /// opening: a film that hasn't started by then on this provider never did), the film is
    /// reopened here at the same point, as you did by hand. At most 3 times in 2 minutes, then it
    /// says it can't be played.
    private func checkStall(_ time: Double) {
        if userPaused || ended || failed || abs(time - lastTime) > 0.1 {
            // Playing on (a small step forward), not the jump to the resume point that the players
            // report while still opening, which took the loading screen away too early.
            let step = time - lastTime
            if lastTime > 0 || time < 3, step > 0.1, step < 3, isPlaying {
                hasPlayed = true
                if !started { withAnimation(.easeOut(duration: 0.4)) { started = true } }
            }
            lastTime = time
            lastAdvance = .now
            return
        }
        guard Date.now.timeIntervalSince(lastAdvance) > (hasPlayed ? 15 : 7) else { return }
        // VLC's own time may be the wrong one after a dropped connection, so VLC reopens at the last
        // good time (`position`); Apple's player keeps the further of the two, as before.
        recover(at: seekHold?.target ?? pendingVLCJump ?? (engine == .vlc ? position : max(position, time)), why: "stall")
    }

    /// Closes the film and opens it again at `at`, after a short pause so the provider has let go
    /// of the old connection (it allows only one, and opening straight away was refused too).
    private func recover(at: Double, why: String) {
        guard let url else { return }
        recoveries = recoveries.filter { Date.now.timeIntervalSince($0) < 120 }
        PlayerLog.add("reopen (\(why)) at \(PlayerLog.t(at)), \(recoveries.count) recent")
        guard recoveries.count < 3 else { set(\.failed, true); return }
        recoveries.append(.now)
        lastRecoverAt = at
        pendingVLCJump = nil
        seekHold = nil
        timer?.invalidate()
        player.stop()
        avPlayer.replaceCurrentItem(with: nil)
        set(\.isBuffering, true)
        let token = startToken
        let apple = engine == .apple
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.startToken == token else { return }
            if apple { self.startApple(self.appleURL ?? url, at: at) } else { self.startVLC(url, at: at) }
        }
    }

    private func hold(_ seconds: Double) {
        position = seconds
        goodAt = .now
        seekHold = (seconds, Date.now.addingTimeInterval(4))
    }

    func stop() {
        startToken = UUID() // an .m3u8 check still running mustn't start the film after closing
        timer?.invalidate()
        timer = nil
        player.stop()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
    }

    func audioTracks() -> [Track] {
        if engine == .apple { return appleTracks(.audible) }
        let list = player.audioTracks().map { Track(id: $0.id, name: $0.name, selected: $0.selected) }
        return list.count < 2 ? [] : list // a single track has nothing to choose between
    }

    func subtitleTracks() -> [Track] {
        if engine == .apple { return appleTracks(.legible) }
        return player.subtitleTracks().map { Track(id: $0.id, name: $0.name, selected: $0.selected) }
    }

    /// Picking a track also remembers it for the next film or episode.
    func selectAudio(_ id: Int32) {
        setTrack(id, audio: true)
        if let name = audioTracks().first(where: { $0.id == id })?.name {
            UserDefaults.standard.set(name, forKey: Self.audioKey)
        }
    }

    func selectSubtitle(_ id: Int32) {
        setTrack(id, audio: false)
        if let name = subtitleTracks().first(where: { $0.id == id })?.name {
            UserDefaults.standard.set(name, forKey: Self.subtitleKey)
        }
    }

    private static let audioKey = "preferredAudioTrack"
    private static let subtitleKey = "preferredSubtitleTrack"

    /// Chooses the tracks last picked by hand: the same name, else the same language
    /// ("English - [English]" matches "English 5.1"). Subtitles "Off" stays off.
    private func applyPreferences() {
        if let wanted = UserDefaults.standard.string(forKey: Self.audioKey),
           let track = Self.match(wanted, in: audioTracks()), !track.selected {
            setTrack(track.id, audio: true)
        }
        if let wanted = UserDefaults.standard.string(forKey: Self.subtitleKey),
           let track = Self.match(wanted, in: subtitleTracks()), !track.selected {
            setTrack(track.id, audio: false)
        }
    }

    static func match(_ wanted: String, in tracks: [Track]) -> Track? {
        if let exact = tracks.first(where: { $0.name == wanted }) { return exact }
        guard wanted != "Off",
              let language = wanted.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init),
              language.count >= 3 else { return nil }
        return tracks.first { $0.id != -1 && $0.name.lowercased().contains(language) }
    }

    private func setTrack(_ id: Int32, audio: Bool) {
        if engine == .vlc {
            if audio { player.selectAudio(id) } else { player.selectSubtitle(id) }
            return
        }
        guard let item = avPlayer.currentItem, let group = appleGroup(audio ? .audible : .legible) else { return }
        let options = group.options
        item.select(id >= 0 && Int(id) < options.count ? options[Int(id)] : nil, in: group)
    }

    /// Apple's player lists tracks as "media selection options"; a track's id is its place in
    /// that list, and subtitles get "Off" as -1 like VLC's.
    private func appleGroup(_ characteristic: AVMediaCharacteristic) -> AVMediaSelectionGroup? {
        avPlayer.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
    }

    private func appleTracks(_ characteristic: AVMediaCharacteristic) -> [Track] {
        guard let item = avPlayer.currentItem, let group = appleGroup(characteristic) else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        var list = group.options.enumerated().map { index, option in
            Track(id: Int32(index), name: option.displayName, selected: option == selected)
        }
        if characteristic == .legible {
            list.insert(Track(id: -1, name: "Off", selected: selected == nil), at: 0)
        }
        // A single audio track has nothing to choose between.
        return characteristic == .audible && list.count < 2 ? [] : list
    }
}

/// Xtream providers can usually hand out a film or episode as an .m3u8 stream as well as its own
/// file (`/movie/u/p/123.mkv` → `/movie/u/p/123.m3u8`), repackaged for Apple's player. Whether a
/// provider does is checked once and remembered per server (a "no" is checked again after a week),
/// with the reason, which Settings → Film player shows.
enum HLSRoute {
    private static let key = "hlsRouteByServer"
    private static let reasonKey = "hlsRouteReason"
    private static let retryNo: TimeInterval = 7 * 24 * 3600

    /// The .m3u8 link for an Xtream film or episode link, else nil.
    static func candidate(for url: URL) -> URL? {
        let path = url.path
        guard path.contains("/movie/") || path.contains("/series/"),
              !url.pathExtension.isEmpty, url.pathExtension.lowercased() != "m3u8" else { return nil }
        return url.deletingPathExtension().appendingPathExtension("m3u8")
    }

    /// true = the copies play, false = they don't, nil = not known yet.
    static func known(for url: URL) -> Bool? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]])?[server(url)],
              entry.count == 2 else { return nil }
        let works = entry[0] == 1
        if !works, Date.now.timeIntervalSince1970 - entry[1] > retryNo { return nil }
        return works
    }

    static func remember(_ works: Bool, for url: URL, reason: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        all[server(url)] = [works ? 1 : 0, Date.now.timeIntervalSince1970]
        UserDefaults.standard.set(all, forKey: key)
        var reasons = UserDefaults.standard.dictionary(forKey: reasonKey) as? [String: String] ?? [:]
        reasons[server(url)] = reason
        UserDefaults.standard.set(reasons, forKey: reasonKey)
    }

    /// For Settings: each server checked so far, whether its copies play, and why.
    static func results() -> [(server: String, works: Bool, reason: String)] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        let reasons = UserDefaults.standard.dictionary(forKey: reasonKey) as? [String: String] ?? [:]
        return all.keys.sorted().map { (server: $0, works: all[$0]?.first == 1, reason: reasons[$0] ?? "") }
    }

    /// Forget every answer, so the next film checks again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: reasonKey)
    }

    /// Asks for the .m3u8 and checks it really is a playlist (some servers answer 200 with an error
    /// page, or send video). Only the first bytes are read and the request is then dropped, so it
    /// doesn't hold on to the provider's one connection while the film opens. nil = it is one,
    /// else why not.
    static func probe(_ url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        let check = Task { () -> String? in
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { return "No answer" }
                guard http.statusCode == 200 else { return "Server answered \(http.statusCode)" }
                var head = [UInt8]()
                for try await byte in bytes {
                    head.append(byte)
                    if head.count >= 16 { break }
                }
                let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.hasPrefix("#EXTM3U") ? nil : "Not an Apple stream"
            } catch {
                return (error as? URLError)?.code == .timedOut ? "No answer within 4 s" : "Couldn't connect"
            }
        }
        // A hard stop too: a server that sends headers and then nothing would otherwise keep it waiting.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            check.cancel()
        }
        let result = await check.value
        timeout.cancel()
        return result
    }

    /// Server only (host and port): never the path, which holds the login.
    private static func server(_ url: URL) -> String {
        "\(url.host ?? "")" + (url.port.map { ":\($0)" } ?? "")
    }
}

/// The double-tap feedback: a soft light from that side of the screen with "10 seconds" (then
/// 20, 30… as taps add up) and the jump arrows.
private struct JumpRipple: View {
    let side: Int
    let seconds: Int
    @State private var grown = false

    var body: some View {
        GeometryReader { geo in
            let forward = side > 0
            ZStack {
                Ellipse()
                    .fill(.white.opacity(grown ? 0.10 : 0.18))
                    .frame(width: geo.size.width * 0.9, height: geo.size.height * 1.6)
                    .scaleEffect(grown ? 1 : 0.85)
                    .position(x: forward ? geo.size.width : 0, y: geo.size.height / 2)
                VStack(spacing: 6) {
                    Image(systemName: forward ? "forward.fill" : "backward.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text("\(seconds) seconds")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .position(x: forward ? geo.size.width * 0.8 : geo.size.width * 0.2, y: geo.size.height / 2)
            }
            .clipped()
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: seconds)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { grown = true } }
    }
}
