#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import SwiftUI

// Mac stand-ins for the few iPhone/iPad (UIKit) names the shared screens use, so those screens
// build unchanged for the Mac. Each one does the Mac's own equivalent, or nothing where the Mac
// has no such thing (haptics, screen rotation, the Home Screen icon menu).

/// A picture. On the Mac that's `NSImage`; these give it the two UIImage calls Lumen uses.
typealias UIImage = NSImage

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? {
        self.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

/// Only `isIdleTimerDisabled`: while a video plays the display doesn't sleep (a power
/// assertion, like QuickTime Player takes).
@MainActor
final class UIApplication {
    static let shared = UIApplication()
    private var assertion: IOPMAssertionID = 0

    var isIdleTimerDisabled = false {
        didSet {
            guard isIdleTimerDisabled != oldValue else { return }
            if isIdleTimerDisabled {
                IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Lumen is playing video" as CFString,
                    &assertion
                )
            } else if assertion != 0 {
                IOPMAssertionRelease(assertion)
                assertion = 0
            }
        }
    }
}

/// Macs have no haptic engine for this (trackpad haptics are for dragging), so nothing happens.
@MainActor
enum Haptics {
    static func select() {}
    static func tap() {}
}

extension View {
    /// iPhone turns sideways for video; a Mac window doesn't rotate.
    func landscapeVideo() -> some View { self }
}

/// macOS has no audio session to set up: sound always plays.
enum AVAudioSessionHelper {
    static func activate() throws {}
}

/// The iPhone's Home Screen icon menu. The Mac uses its menu bar instead (`LumenCommands`), so
/// only `pending` is used, by the File menu's Search.
@MainActor
@Observable
final class QuickActions {
    static let shared = QuickActions()

    enum Action: Equatable {
        case search
        case resume(key: String, playlistID: UUID)
    }

    var pending: Action?

    func refresh(store: PlaylistStore) {}
}
#endif
