import AVFoundation
import AVKit
import SwiftUI
import VLCKitSPM

/// Full-screen film/episode player. Films in formats Apple's player opens (.mp4, .m4v, .mov,
/// .m3u8) play through it, so they get Picture in Picture. Everything else (most Xtream films are
/// .mkv, often with DTS audio) plays through VLC (VLCKit 3), which has no Picture in Picture.
/// If Apple's player fails or shows no picture, the film moves to VLC at the same point.
/// Tap shows the controls; double-tap the left/right side skips 10 s back/forward.
/// In a series, "Skip intro" / "Skip recap" shows while that part plays and "Next episode" in the
/// end credits, from the intro databases (`SkipTimes`); nothing shows when they don't know the episode.
struct VodPlayerView: View {
    let playback: VodPlayback
    let playlist: Playlist
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = VodPlayerModel()
    /// Swipe down to close: how far the picture has been pulled down.
    @State private var pull: CGFloat = 0
    @State private var pip = PictureInPicture()
    @State private var current: VodPlayback
    @State private var queue: [VodPlayback]
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var skips: [SkipSegment] = []
    /// The segment whose pill was swiped away, so it stays away.
    @State private var skipDismissed: Double?

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
            VLCVideoView(model: model).ignoresSafeArea()
            PlayerLayerView(player: model.avPlayer, onLayer: { layer in
                model.layer = layer
                pip.attach(layer)
            })
            .ignoresSafeArea()
            .opacity(model.engine == .apple ? 1 : 0)

            // Double-tap halves: back 10 s on the left, forward 10 s on the right; one tap toggles
            // the controls. (The double tap is declared first so a single tap waits for it.)
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.skip(-10); showControls() }
                    .onTapGesture { toggleControls() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.skip(10); showControls() }
                    .onTapGesture { toggleControls() }
            }

            if model.isBuffering && !model.failed {
                ProgressView().controlSize(.large).tint(.white)
            }
            if model.failed {
                Text("This video can't be played right now.")
                    .font(LumenFont.body)
                    .padding(20)
                    .glass(fill: .black.opacity(0.6))
            }
            if controlsVisible { controls.transition(.opacity) }
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
        // Swipe down to close, as in Apple's own players: the picture follows the finger, and
        // letting go far enough closes it (otherwise it springs back).
        .offset(y: pull)
        .scaleEffect(1 - min(pull, 400) / 2000)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { drag in
                    guard scrubbing == nil, drag.translation.height > 0,
                          drag.translation.height > abs(drag.translation.width) else { return }
                    pull = drag.translation.height
                }
                .onEnded { drag in
                    if pull > 140 || (pull > 40 && drag.predictedEndTranslation.height > 400) {
                        dismiss()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { pull = 0 }
                    }
                }
        )
        .landscapeVideo()
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.start(current.streamUrl, at: current.startAt)
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
        }
        .onDisappear {
            saveProgress()
            pip.stop()
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

    private var controls: some View {
        VStack {
            HStack {
                Text(current.title).font(LumenFont.headline).lineLimit(1)
                Spacer()
                if model.engine == .apple && pip.isSupported {
                    Button { pip.toggle() } label: {
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .disabled(!pip.isPossible)
                    .opacity(pip.isPossible ? 1 : 0.4)
                    .accessibilityLabel("Picture in Picture")
                }
                TrackMenu(model: model)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
            }
            .foregroundStyle(LumenColors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glass(fill: .black.opacity(0.5))
            .padding(16)

            Spacer()

            HStack(spacing: 44) {
                Button { model.skip(-10); showControls() } label: { Image(systemName: "gobackward.10") }
                Button { model.togglePause(); showControls() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 44)
                }
                Button { model.skip(10); showControls() } label: { Image(systemName: "goforward.10") }
            }
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)

            Spacer()

            VStack(spacing: 6) {
                ScrubBar(model: model, scrubbing: $scrubbing, touched: showControls)
                if !queue.isEmpty {
                    Button {
                        saveProgress()
                        playNext()
                    } label: {
                        Label("Next episode", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(16)
            .glass(fill: .black.opacity(0.5))
            .padding(16)
        }
    }


    private func playNext() {
        guard let next = queue.first else { return }
        queue.removeFirst()
        current = next
        model.start(next.streamUrl, at: 0)
        showControls()
    }

    private func saveProgress(finished: Bool = false, quietly: Bool = false) {
        var item = current.progress
        let duration = model.duration > 0 ? model.duration : item.duration
        guard duration > 0 || model.position > 0 else { return }
        item.duration = duration
        item.position = finished ? duration : model.position
        item.updated = .now
        store.saveProgress(item, in: playlist, quietly: quietly)
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying, scrubbing == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// The progress bar and times. Its own view because it reads the position, which changes twice
/// a second: only this part redraws then, not the whole player. While you drag, the picture
/// follows your finger (`VodPlayerModel.scrub`); letting go lands exactly there.
struct ScrubBar: View {
    let model: VodPlayerModel
    @Binding var scrubbing: Double?
    let touched: () -> Void

    var body: some View {
        let shown = scrubbing ?? model.position
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { shown },
                    set: { value in
                        scrubbing = value
                        model.scrub(to: value)
                        touched()
                    }
                ),
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        model.seek(to: target)
                        scrubbing = nil
                    }
                }
            )
            .tint(.white)
            HStack {
                Text(formatTime(shown))
                    .font(scrubbing == nil ? LumenFont.caption : LumenFont.inter(15, .semibold))
                    .foregroundStyle(scrubbing == nil ? LumenColors.textSecondary : LumenColors.textPrimary)
                Spacer()
                Text("-" + formatTime(max(0, model.duration - shown)))
            }
            .font(LumenFont.caption)
            .foregroundStyle(LumenColors.textSecondary)
            .monospacedDigit()
        }
    }
}

/// "Skip intro" / "Skip recap" / "Next episode": a white pill like the TV's, bottom right. Tap
/// skips; swipe it away to hide it. Its own view for the same reason as `ScrubBar`.
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
                .padding(.bottom, controlsVisible ? 150 : 32)
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

/// Audio and subtitle choice, the iOS way: one menu.
struct TrackMenu: View {
    let model: VodPlayerModel

    var body: some View {
        Menu {
            let audio = model.audioTracks()
            if !audio.isEmpty {
                Section("Audio") {
                    ForEach(audio, id: \.id) { track in
                        Button { model.selectAudio(track.id) } label: {
                            if track.selected { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                        }
                    }
                }
            }
            let subtitles = model.subtitleTracks()
            if !subtitles.isEmpty {
                Section("Subtitles") {
                    ForEach(subtitles, id: \.id) { track in
                        Button { model.selectSubtitle(track.id) } label: {
                            if track.selected { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Audio and subtitles")
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

    @ObservationIgnored let player = VLCMediaPlayer()
    @ObservationIgnored let avPlayer = AVPlayer()
    /// Apple's video layer, to tell "sound but no picture" (e.g. HEVC it can't show).
    @ObservationIgnored weak var layer: AVPlayerLayer?
    private(set) var engine: Engine = .vlc
    @ObservationIgnored private var url: URL?
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
    /// Whether the remembered audio/subtitle language has been picked for this film yet.
    @ObservationIgnored private var appliedPreferences = false

    init() {
        try? AVAudioSessionHelper.activate()
    }

    /// Containers Apple's player opens. Everything else goes straight to VLC.
    static func prefersApple(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "m3u8"].contains(url.pathExtension.lowercased())
    }

    func start(_ url: String, at seconds: Double) {
        player.stop()
        avPlayer.replaceCurrentItem(with: nil)
        guard let parsed = URL(string: url) else { failed = true; return }
        self.url = parsed
        pendingVLCJump = nil
        seekHold = nil
        recoveries = []
        if Self.prefersApple(parsed) {
            startApple(parsed, at: seconds)
        } else {
            startVLC(parsed, at: seconds)
        }
    }

    private func resetState(at seconds: Double) {
        position = seconds
        duration = 0
        failed = false
        ended = false
        isBuffering = true
        appliedPreferences = false
        userPaused = false
        lastTime = -1
        lastAdvance = .now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func startApple(_ url: URL, at seconds: Double) {
        engine = .apple
        appleStartAt = seconds
        appleStarted = false
        applePlayingSince = nil
        avPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        resetState(at: seconds)
    }

    /// Apple's player couldn't (fail, or no picture): carry on in VLC from the same point.
    private func moveToVLC() {
        guard let url else { return }
        let at = max(position, appleStartAt)
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        startVLC(url, at: at)
    }

    private func startVLC(_ parsed: URL, at seconds: Double) {
        engine = .vlc
        let media = VLCMedia(url: parsed)
        if seconds > 1 { media.addOption(":start-time=\(Int(seconds))") }
        // A network buffer (ms) to ride out slow provider servers. It's also how long a film takes
        // to start (and to resume after a jump): 3 s felt slow, 1.5 s still rides out hiccups.
        media.addOption(":network-caching=1500")
        player.media = media
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
    }

    private func set<T: Equatable>(_ path: ReferenceWritableKeyPath<VodPlayerModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func poll() {
        if engine == .apple { pollApple(); return }
        let time = Double(player.time.intValue) / 1000
        if let target = pendingVLCJump, player.isPlaying, player.isSeekable {
            pendingVLCJump = nil
            player.time = VLCTime(int: Int32(target * 1000))
        }
        checkStall(time)
        update(position: time)
        if let length = player.media?.length.intValue, length > 0 { set(\.duration, Double(length) / 1000) }
        set(\.isPlaying, player.isPlaying)
        if !appliedPreferences, player.isPlaying, !audioTracks().isEmpty {
            appliedPreferences = true
            applyPreferences()
        }
        switch player.state {
        case .error: set(\.failed, true)
        case .ended: set(\.ended, true)
        case .buffering, .opening: set(\.isBuffering, !player.isPlaying)
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
            // Sound for 2 s but still no picture: Apple's player can't show this video.
            if let layer, !layer.isReadyForDisplay, Date.now.timeIntervalSince(since) > 2 {
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
        appleScrubNext = nil
        if engine == .apple {
            if appleStarted {
                avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                appleStartAt = seconds // not open yet: it starts there instead
            }
        } else if player.isPlaying, player.isSeekable {
            player.time = VLCTime(int: Int32(seconds * 1000))
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
        player.time = VLCTime(int: Int32(seconds * 1000))
    }

    /// Some provider servers stop answering after a jump (they allow one connection, and the
    /// jump opens a new one before the old one closes), which left the film frozen until it was
    /// reopened. When the picture hasn't moved for 15 s without you pausing, the film is reopened
    /// here at the same point, as you did by hand. At most 3 times in 2 minutes, then it says
    /// it can't be played.
    private func checkStall(_ time: Double) {
        if userPaused || ended || failed || abs(time - lastTime) > 0.1 {
            lastTime = time
            lastAdvance = .now
            return
        }
        guard Date.now.timeIntervalSince(lastAdvance) > 15, let url else { return }
        recoveries = recoveries.filter { Date.now.timeIntervalSince($0) < 120 }
        guard recoveries.count < 3 else { failed = true; return }
        recoveries.append(.now)
        let at = seekHold?.target ?? pendingVLCJump ?? max(position, time)
        pendingVLCJump = nil
        seekHold = nil
        player.stop()
        avPlayer.replaceCurrentItem(with: nil)
        if engine == .apple { startApple(url, at: at) } else { startVLC(url, at: at) }
    }

    private func hold(_ seconds: Double) {
        position = seconds
        seekHold = (seconds, Date.now.addingTimeInterval(4))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.stop()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
    }

    func audioTracks() -> [Track] {
        if engine == .apple { return appleTracks(.audible) }
        return tracks(names: player.audioTrackNames, ids: player.audioTrackIndexes, current: player.currentAudioTrackIndex)
    }

    func subtitleTracks() -> [Track] {
        if engine == .apple { return appleTracks(.legible) }
        return tracks(names: player.videoSubTitlesNames, ids: player.videoSubTitlesIndexes, current: player.currentVideoSubTitleIndex)
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
            if audio { player.currentAudioTrackIndex = id } else { player.currentVideoSubTitleIndex = id }
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

    private func tracks(names: [Any], ids: [Any], current: Int32) -> [Track] {
        zip(names, ids).compactMap { name, id in
            guard let id = (id as? NSNumber)?.int32Value else { return nil }
            // VLC lists "Disable" as track -1.
            let label = id == -1 ? "Off" : (name as? String ?? "Track \(id)")
            return Track(id: id, name: label, selected: id == current)
        }
    }
}

/// The view VLC draws the video into.
struct VLCVideoView: UIViewRepresentable {
    let model: VodPlayerModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false // taps belong to the controls above
        model.player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
