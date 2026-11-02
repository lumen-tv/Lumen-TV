import SwiftUI
import UIKit

/// iPhone: video turns the screen sideways by itself, and browsing comes back upright when the
/// player closes, as in other video apps. (iPad: nothing changes; it shows video well either way.)
///
/// SwiftUI has no setting for this, so a small UIKit app delegate answers which orientations are
/// allowed (`mask`), and the window is asked to rotate.
@MainActor
enum ScreenOrientation {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    static func landscapeForVideo() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        apply(.landscape, prefer: .landscapeRight)
    }

    static func back() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        apply(.allButUpsideDown, prefer: .portrait)
    }

    private static func apply(_ newMask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        mask = newMask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // The player sits in a view controller presented over the root: tell each of them.
            var controller = scene.keyWindow?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask == .landscape ? .landscape : prefer)) { _ in }
        }
    }
}

/// Only here to tell iOS which orientations are allowed right now (see `ScreenOrientation`).
final class LumenAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { ScreenOrientation.mask }
    }
}

extension View {
    /// A full-screen player: sideways on iPhone while it's open.
    func landscapeVideo() -> some View {
        onAppear { ScreenOrientation.landscapeForVideo() }
            .onDisappear { ScreenOrientation.back() }
    }
}
