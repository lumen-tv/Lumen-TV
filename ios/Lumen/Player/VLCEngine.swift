import SwiftUI
import SwiftVLC

/// VLC 4 (libVLC 4 through the SwiftVLC package, MIT; libVLC itself is LGPL 2.1), for films and
/// channels Apple's player can't open (.mkv, DTS sound, HEVC 4K channels). It replaced VLCKit 3
/// (Hayat 2026-11-02): VLC 4 jumps through a film better and has Picture in Picture.
///
/// This class is the only place that talks to SwiftVLC, so the players keep a small, simple
/// surface (seconds as Doubles, tracks as numbers with -1 = off), and switching VLC versions again
/// would only touch this file. (SwiftVLC also has a type called `Track`, which would clash with
/// the film player's own.)
@MainActor
final class VLCEngine {
    enum State { case opening, playing, paused, stopped, ended, error }

    let player = Player()

    /// Opens `url` without starting it (`play()` starts it). `options` are VLC's own, such as
    /// ":network-caching=1500" or ":start-time=120".
    func open(_ url: URL, options: [String]) -> Bool {
        guard let media = try? Media(url: url) else { return false }
        for option in options { media.addOption(option) }
        player.load(media)
        return true
    }

    func play() {
        if player.state == .paused { player.resume() } else { try? player.play() }
    }

    func pause() { player.pause() }

    /// Pinch to fill: the picture covers the whole screen (edges cropped) instead of fitting.
    func setFill(_ fill: Bool) { player.aspectRatio = fill ? .fill : .default }

    /// Playback speed (1 = normal). VLC applies it a moment later.
    func setRate(_ rate: Float) { try? player.setPlaybackRate(PlaybackRate(rate)) }
    func stop() { player.stop() }

    var isPlaying: Bool { player.state == .playing }
    var isSeekable: Bool { player.isSeekable }

    /// Where it is, in seconds.
    var time: Double { Double(player.currentTime.milliseconds) / 1000 }

    /// The film's length in seconds, 0 while unknown.
    var length: Double { player.duration.map { Double($0.milliseconds) / 1000 } ?? 0 }

    /// Jumps to `seconds`. `fast` lands on the nearest keyframe (for dragging the bar).
    func jump(to seconds: Double, fast: Bool = false) {
        try? player.seek(to: .milliseconds(Int64(max(0, seconds) * 1000)), fast: fast)
    }

    var state: State {
        if player.didReachEnd { return .ended }
        switch player.state {
        case .idle, .opening, .buffering: return .opening
        case .playing: return .playing
        case .paused: return .paused
        case .stopped, .stopping: return .stopped
        case .error: return .error
        default: return .opening // states a later SwiftVLC adds
        }
    }

    // Tracks: the id is the track's place in VLC's list (VLC 4's own ids are text), -1 = off.

    func audioTracks() -> [(id: Int32, name: String, selected: Bool)] {
        player.audioTracks.enumerated().map { index, track in
            (Int32(index), Self.label(track.name, index), track.isSelected)
        }
    }

    func subtitleTracks() -> [(id: Int32, name: String, selected: Bool)] {
        let tracks = player.subtitleTracks
        var list = tracks.enumerated().map { index, track in
            (id: Int32(index), name: Self.label(track.name, index), selected: track.isSelected)
        }
        list.insert((id: -1, name: "Off", selected: !tracks.contains(where: \.isSelected)), at: 0)
        return list
    }

    func selectAudio(_ id: Int32) {
        let tracks = player.audioTracks
        guard id >= 0, Int(id) < tracks.count else { return }
        player.selectedAudioTrack = tracks[Int(id)]
    }

    func selectSubtitle(_ id: Int32) {
        let tracks = player.subtitleTracks
        player.selectedSubtitleTrack = id >= 0 && Int(id) < tracks.count ? tracks[Int(id)] : nil
    }

    private static func label(_ name: String, _ index: Int) -> String {
        name.isEmpty ? "Track \(index + 1)" : name
    }
}

/// The picture VLC draws into, with Picture in Picture. `pip` gets VLC's PiP controller once the
/// view exists (it can start PiP once a film is showing; it starts by itself when you leave the
/// app while it plays). Taps go to the controls above it, not to this view.
struct VLCVideo: View {
    let engine: VLCEngine
    @Binding var pip: VLCPiP?

    @State private var controller: PiPController?

    var body: some View {
        PiPVideoView(engine.player, controller: $controller)
            .allowsHitTesting(false)
            .onChange(of: controller.map { ObjectIdentifier($0) }) { _, _ in
                pip = controller.map { VLCPiP(controller: $0) }
            }
            .onAppear { pip = controller.map { VLCPiP(controller: $0) } }
    }
}

/// VLC's Picture in Picture, as the players need it (so they don't import SwiftVLC).
@MainActor
struct VLCPiP {
    fileprivate let controller: PiPController
    var isPossible: Bool { controller.isPossible }
    var isActive: Bool { controller.isActive }
    func toggle() { if controller.isActive { controller.stop() } else { controller.start() } }
    func stop() { controller.stop() }
}
