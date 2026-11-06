#if os(macOS)
import AppKit
import AudioToolbox
import AVFoundation
import AVKit
import CoreAudio
import SwiftUI

// The Mac (AppKit) versions of the players' small UIKit views: the video layer, the AirPlay
// button and the volume. Same names and calls as on iPhone/iPad, so the players are shared.

/// Shows an AVPlayer through an AVPlayerLayer (see the iOS one in LivePlayerView.swift).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var onLayer: ((AVPlayerLayer) -> Void)?

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        var onWindow: ((AVPlayerLayer) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // AppKit views only get a layer when asked; the player layer fills it.
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = bounds
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onWindow?(playerLayer) }
        }

        // Clicks belong to the SwiftUI controls on top.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.onWindow = onLayer
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}

/// Apple's AirPlay button (Apple TV or AirPlay speakers), white to match the overlay.
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(NSColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 1), for: .active)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

/// The Mac's own output volume (what the volume keys change), for the player's volume bar.
@MainActor
@Observable
final class SystemVolume {
    private(set) var level: Float = 1
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init() {
        level = Self.read() ?? 1
        // The volume keys change it too; a light check twice a second keeps the bar in step.
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let now = Self.read(), abs(now - self.level) > 0.001 else { continue }
                self.level = now
            }
        }
    }

    deinit { watcher?.cancel() }

    func set(_ value: Float) {
        let clamped = min(1, max(0, value))
        level = clamped
        Self.write(clamped)
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func outputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func read() -> Float? {
        guard let device = outputDevice() else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private static func write(_ value: Float) {
        guard let device = outputDevice() else { return }
        var volume = Float32(value)
        var address = volumeAddress
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }
}

/// iPhone needs a hidden system volume view to set the volume; the Mac doesn't.
struct HiddenVolumeView: View {
    let volume: SystemVolume
    var body: some View { Color.clear }
}
#endif
