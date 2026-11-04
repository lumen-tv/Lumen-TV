import MediaPlayer
import UIKit

/// What's playing, on the lock screen, in Control Center and on a paired watch: the poster,
/// title, timeline and play/pause/skip, as Apple's own player shows them. Both players (films
/// and live TV) fill it in; Apple's player doesn't do it by itself when it isn't
/// AVPlayerViewController, and VLC never does.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    struct Controls {
        var togglePause: @MainActor () -> Void
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        /// Seconds forward (or back, negative). Nil for live TV.
        var skip: (@MainActor (Double) -> Void)? = nil
        /// Jump to a point (seconds). Nil for live TV.
        var seek: (@MainActor (Double) -> Void)? = nil
        /// Live TV: the next and previous channel.
        var nextTrack: (@MainActor () -> Void)? = nil
        var previousTrack: (@MainActor () -> Void)? = nil
    }

    private var owner = UUID()
    private var controls: Controls?
    private var info: [String: Any] = [:]
    private var commandsSet = false

    /// Starts showing a new film, episode or channel. Returns a token for `update` and `end`, so
    /// a player closing late doesn't clear the next one's entry.
    @discardableResult
    func begin(title: String, subtitle: String?, artwork: URL?, live: Bool, controls: Controls) -> UUID {
        let token = UUID()
        owner = token
        self.controls = controls
        setUpCommands()
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = controls.skip != nil
        center.skipBackwardCommand.isEnabled = controls.skip != nil
        center.changePlaybackPositionCommand.isEnabled = controls.seek != nil
        center.nextTrackCommand.isEnabled = controls.nextTrack != nil
        center.previousTrackCommand.isEnabled = controls.previousTrack != nil

        info = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: live,
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if let artwork {
            Task {
                guard let image = await ImagePipeline.shared.image(artwork, maxPixels: 600), self.owner == token else { return }
                self.info[MPMediaItemPropertyArtwork] = Self.artwork(image)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
            }
        }
        return token
    }

    /// Where it is. iOS moves the lock screen's timeline along by itself from `rate`, so this only
    /// needs calling every few seconds and when playing/pausing or jumping.
    func update(_ token: UUID, position: Double?, duration: Double?, playing: Bool, rate: Float = 1) {
        guard token == owner else { return }
        if let position { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        if let duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(rate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    func end(_ token: UUID) {
        guard token == owner else { return }
        controls = nil
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// The command handlers are added once and call whichever player is current.
    private func setUpCommands() {
        guard !commandsSet else { return }
        commandsSet = true
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        // iOS calls these on the main thread; `assumeIsolated` says so to Swift.
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Controls, MPRemoteCommandEvent) -> Void) {
            command.addTarget { event in
                MainActor.assumeIsolated { NowPlaying.shared.run { action($0, event) } }
            }
        }
        on(center.togglePlayPauseCommand) { controls, _ in controls.togglePause() }
        on(center.playCommand) { controls, _ in controls.play() }
        on(center.pauseCommand) { controls, _ in controls.pause() }
        on(center.skipForwardCommand) { controls, _ in controls.skip?(10) }
        on(center.skipBackwardCommand) { controls, _ in controls.skip?(-10) }
        on(center.nextTrackCommand) { controls, _ in controls.nextTrack?() }
        on(center.previousTrackCommand) { controls, _ in controls.previousTrack?() }
        on(center.changePlaybackPositionCommand) { controls, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { controls.seek?(event.positionTime) }
        }
    }

    /// Made outside the main actor: iOS asks for the picture from a background thread.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func run(_ action: (Controls) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let controls else { return .noActionableNowPlayingItem }
        action(controls)
        return .success
    }
}
