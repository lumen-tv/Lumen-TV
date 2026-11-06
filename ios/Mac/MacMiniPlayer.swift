#if os(macOS)
import AppKit
import SwiftUI

// The mini player: a small always-on-top panel holding the very player that was in the window.
// `PlayerStage` moves its view here, so the stream carries on without reopening (providers allow
// one connection). AppKit buttons rather than SwiftUI ones, because they also have to work while
// another app is in front.

/// The floating window. It can take the keyboard (Space, Esc) when clicked.
final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make() -> MiniPanel {
        let panel = MiniPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .black
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 256, height: 144)
        // Stays in front when you change desktops or another app is full screen.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // Where you last left it, else the bottom right of the screen.
        if !panel.setFrameUsingName("LumenMiniPlayer"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 480 - 24, y: screen.minY + 24))
        }
        panel.setFrameAutosaveName("LumenMiniPlayer")
        panel.contentView = MiniContent()
        return panel
    }

    var content: MiniContent? { contentView as? MiniContent }
}

/// The picture, with the buttons over it while the pointer is on the panel. Dragging anywhere moves
/// the panel, and a double-click puts it back in the window.
final class MiniContent: NSView {
    private let controls = NSView()
    private let playButton = MiniButton(symbol: "pause.fill", size: 52, label: "Play or pause")
    private var refresher: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        controls.frame = bounds
        controls.autoresizingMask = [.width, .height]
        controls.alphaValue = 0
        addSubview(controls)

        let close = MiniButton(symbol: "xmark", size: 34, label: "Close")
        close.handler = { PlayerStage.shared.closeCurrent() }
        let expand = MiniButton(symbol: "arrow.up.left.and.arrow.down.right", size: 34, label: "Back to the main window")
        expand.handler = { PlayerStage.shared.expand() }
        playButton.handler = { [weak self] in
            MacPlayback.shared.actions?.togglePause()
            self?.refreshPlayButton()
        }
        for button in [close, expand, playButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(button)
        }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 10),
            close.topAnchor.constraint(equalTo: controls.topAnchor, constant: 10),
            expand.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -10),
            expand.topAnchor.constraint(equalTo: controls.topAnchor, constant: 10),
            playButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes the player's view. A direct `addSubview`, never `removeFromSuperview` first: taking a
    /// SwiftUI host out of its window fires its `onDisappear`, which would stop the film.
    func hold(_ host: NSView) {
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host, positioned: .below, relativeTo: controls)
    }

    // The player underneath never gets the mouse: only the buttons, and this view for dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return controls.hitTest(convert(point, from: superview)).flatMap { $0 is MiniButton ? $0 : nil } ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            PlayerStage.shared.expand()
        } else {
            window?.performDrag(with: event)
        }
    }

    // `.activeAlways`: the buttons also come up while another app is in front.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        refreshPlayButton()
        setControls(visible: true)
        // The film can pause or end by itself while the buttons show.
        refresher?.invalidate()
        refresher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlayButton() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        setControls(visible: false)
        refresher?.invalidate()
        refresher = nil
    }

    private func setControls(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func refreshPlayButton() {
        let playing = MacPlayback.shared.actions?.isPlaying() ?? false
        playButton.setSymbol(playing ? "pause.fill" : "play.fill")
    }
}

/// A round dark button with a white symbol, clickable on the first click.
final class MiniButton: NSButton {
    var handler: (() -> Void)?
    private var symbol = ""
    private let side: CGFloat

    init(symbol: String, size: CGFloat, label: String) {
        side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = size / 2
        setAccessibilityLabel(label)
        toolTip = label
        target = self
        action = #selector(pressed)
        setSymbol(symbol)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        let config = NSImage.SymbolConfiguration(pointSize: side * 0.42, weight: .semibold)
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func pressed() { handler?() }
}
#endif
