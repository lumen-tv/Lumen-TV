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

    func attach(_ layer: AVPlayerLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
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
