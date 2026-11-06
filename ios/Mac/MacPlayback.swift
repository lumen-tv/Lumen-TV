#if os(macOS)
import SwiftUI

/// What the player showing right now can do, for what lives outside it: the mini player's buttons
/// and the Playback menu. Live TV and films fill in different ones; nil means it can't.
struct MacPlaybackActions {
    var isPlaying: () -> Bool
    var togglePause: () -> Void
    var back: (() -> Void)?
    var forward: (() -> Void)?
    var previousChannel: (() -> Void)?
    var nextChannel: (() -> Void)?
    var nextEpisode: (() -> Void)?
    var audioTracks: (() -> [Track])?
    var subtitleTracks: (() -> [Track])?
    var selectAudio: ((Int32) -> Void)?
    var selectSubtitle: ((Int32) -> Void)?
}

/// The registry: the player showing puts its actions here and takes them away when it goes.
@MainActor
@Observable
final class MacPlayback {
    static let shared = MacPlayback()

    private(set) var actions: MacPlaybackActions?
    @ObservationIgnored private var owner: UUID?

    func register(_ actions: MacPlaybackActions, owner: UUID) {
        self.owner = owner
        self.actions = actions
    }

    /// A closing player can go after the next one has arrived, so only its own actions are removed.
    func clear(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        actions = nil
    }
}

extension View {
    /// Registers the player's actions while it shows. `refresh` is what they depend on, for
    /// example whether there's a next episode.
    func macPlayback<Key: Equatable>(refresh: Key, _ actions: @escaping () -> MacPlaybackActions) -> some View {
        modifier(MacPlaybackRegistration(refresh: refresh, actions: actions))
    }
}

private struct MacPlaybackRegistration<Key: Equatable>: ViewModifier {
    let refresh: Key
    let actions: () -> MacPlaybackActions
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { MacPlayback.shared.register(actions(), owner: owner) }
            .onChange(of: refresh) { _, _ in MacPlayback.shared.register(actions(), owner: owner) }
            .onDisappear { MacPlayback.shared.clear(owner: owner) }
    }
}
#endif
