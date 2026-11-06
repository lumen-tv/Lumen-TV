#if os(macOS)
import AppKit
import SwiftUI

// The player with a mouse or trackpad: one click shows or hides the controls at once, a double
// click is full screen, a pinch fills or fits the picture, and two fingers seek and change the volume.

/// Sits on the picture, under the controls. AppKit's own click count, because SwiftUI's double-tap
/// gesture makes a single click wait to see whether a second follows.
struct MacClickSurface: NSViewRepresentable {
    let click: () -> Void
    let doubleClick: () -> Void
    var pinch: ((CGFloat) -> Void)?

    final class Surface: NSView {
        var click: (() -> Void)?
        var doubleClick: (() -> Void)?
        var pinch: ((CGFloat) -> Void)?
        private var pinched: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 1 { click?() }
            if event.clickCount == 2 { doubleClick?() }
        }

        override func magnify(with event: NSEvent) {
            pinched += event.magnification
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                pinch?(pinched)
                pinched = 0
            }
        }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {
        view.click = click
        view.doubleClick = doubleClick
        view.pinch = pinch
    }
}

extension View {
    /// Two-finger scrolling over the player in the main window. A swipe sticks to the direction it
    /// started in. `seek` gets how far the fingers have moved sideways so far (points, right is
    /// positive) and `seekEnded` the total when they lift, so one swipe is one jump; nil for live
    /// TV. `volume` gets changes to add, up is louder. While `blocked` the scrolling is left alone.
    func macPlayerScroll(
        blocked: @escaping () -> Bool = { false },
        seek: ((CGFloat) -> Void)? = nil,
        seekEnded: ((CGFloat) -> Void)? = nil,
        volume: @escaping (Float) -> Void
    ) -> some View {
        modifier(MacPlayerScroll(blocked: blocked, seek: seek, seekEnded: seekEnded, volume: volume))
    }
}

private struct MacPlayerScroll: ViewModifier {
    let blocked: () -> Bool
    let seek: ((CGFloat) -> Void)?
    let seekEnded: ((CGFloat) -> Void)?
    let volume: (Float) -> Void

    private enum Axis { case sideways, upDown }

    /// The swipe in progress.
    private final class Swipe {
        var axis: Axis?
        var sideways: CGFloat = 0
    }

    @State private var monitor: Any?
    @State private var swipe = Swipe()

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let swipe = swipe
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    MainActor.assumeIsolated { handle(event, swipe) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// Whether the event was used.
    @MainActor
    private func handle(_ event: NSEvent, _ swipe: Swipe) -> Bool {
        guard !PlayerStage.shared.isMini, event.window === MacWindow.main, !blocked() else { return false }
        // The glide after the fingers lift isn't part of the swipe.
        if event.momentumPhase != [] { return true }
        // With natural scrolling the deltas follow the fingers; without it they're reversed.
        let natural = event.isDirectionInvertedFromDevice
        let right = natural ? event.scrollingDeltaX : -event.scrollingDeltaX
        let up = natural ? -event.scrollingDeltaY : event.scrollingDeltaY
        // A mouse wheel has no phases: each notch is just a volume step.
        if event.phase == [] {
            if up != 0 { volume(Float(up) * (event.hasPreciseScrollingDeltas ? 0.002 : 0.03)) }
            return true
        }
        if event.phase.contains(.began) {
            swipe.axis = nil
            swipe.sideways = 0
        }
        if swipe.axis == nil, abs(right) + abs(up) >= 1 {
            swipe.axis = abs(right) > abs(up) ? .sideways : .upDown
        }
        switch swipe.axis {
        case .sideways:
            swipe.sideways += right
            seek?(swipe.sideways)
        case .upDown:
            volume(Float(up) * 0.002)
        case nil:
            break
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if swipe.axis == .sideways { seekEnded?(swipe.sideways) }
            swipe.axis = nil
        }
        return true
    }
}
#endif
