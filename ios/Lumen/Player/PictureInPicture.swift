import AVKit
import Observation

/// Picture in Picture for live TV: the channel keeps playing in a small window over other apps.
/// Starts by itself when you leave the app while a channel is full screen, or with the button in
/// the player. Needs the "audio" background mode (project.yml) and the playback audio session.
/// Films and episodes play through VLCKit, which has no Picture in Picture, so they don't have it.
@MainActor
@Observable
final class PictureInPicture: NSObject {
    private(set) var isPossible = false
    private(set) var isActive = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possible: NSKeyValueObservation?

    /// True on every iPhone and iPad that can do Picture in Picture at all. The button shows
    /// whenever this is true (dimmed until the stream is ready), so it never just vanishes.
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    /// Called once the video layer is on screen (in a window). Building the controller earlier,
    /// before the layer was in a window, left it stuck at "not possible" on the iPad, so neither
    /// the button nor the automatic start on leaving the app worked there.
    func attach(_ layer: AVPlayerLayer) {
        guard isSupported else { return }
        if let controller, controller.contentSource?.playerLayer === layer { return }
        controller?.delegate = nil
        possible = nil
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        possible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let value = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = value }
        }
        self.controller = controller
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }
}

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    /// The full-screen player is still open behind the small window, so there's nothing to rebuild.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
