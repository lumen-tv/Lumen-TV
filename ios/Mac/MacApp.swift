#if os(macOS)
import AppKit
import SwiftUI

/// Lumen is one window: closing it quits, as with other single-window Mac apps.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The mini player mustn't keep Lumen running without its window: there'd be nowhere to go back to.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.frameAutosaveName == "main" else { return }
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        // Full screen rebuilds the window's title bar, and the window isn't there until it's shown.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willEnterFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MacWindow.updateChrome() }
            }
        }
    }
}

/// The menu bar: Search (⌘F), the tabs (⌘1–⌘4), Settings (⌘,) and Check for Updates.
struct LumenCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { MacMenu.shared.open(.settings) }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await MacUpdates.shared.check(userAsked: true) } }
        }
        // One window only, so no New Window.
        CommandGroup(replacing: .newItem) {
            Button("Search") { QuickActions.shared.pending = .search }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(AppTab.allCases.filter { $0 != .settings }.enumerated()), id: \.element) { number, tab in
                Button(tab.title) { MacMenu.shared.open(tab) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number + 1)")))
            }
            Divider()
        }
        CommandMenu("Playback") { PlaybackMenu() }
    }
}

/// The Playback menu: enabled while a player shows, through what it put in `MacPlayback`. Space,
/// the arrows and F are named in the titles rather than set as menu shortcuts: the player's key
/// monitor already handles them, and as menu shortcuts they'd also catch typing in the search
/// field while the mini player runs.
private struct PlaybackMenu: View {
    private var actions: MacPlaybackActions? { MacPlayback.shared.actions }
    private var showing: Bool { PlayerStage.shared.showing != nil }

    var body: some View {
        // Read so the menu is rebuilt when the film starts, which is when its tracks are known.
        let _ = actions?.isPlaying()
        Button("Play/Pause (Space)") { actions?.togglePause() }
            .disabled(actions == nil)
        item("Back 10 Seconds (←)", actions?.back)
        item("Forward 10 Seconds (→)", actions?.forward)
        Divider()
        item("Previous Channel (↑)", actions?.previousChannel)
        item("Next Channel (↓)", actions?.nextChannel)
        item("Next Episode", actions?.nextEpisode)
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Divider()
        tracks("Audio", actions?.audioTracks?() ?? [], select: actions?.selectAudio)
        tracks("Subtitles", actions?.subtitleTracks?() ?? [], select: actions?.selectSubtitle)
        Divider()
        Button("Mini Player") { PlayerStage.shared.toggleMini() }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(!showing)
        Button("Full Screen (F)") { MacWindow.toggleFullScreen() }
            .disabled(!showing)
    }

    private func item(_ title: String, _ action: (() -> Void)?) -> some View {
        Button(title) { action?() }.disabled(action == nil)
    }

    private func tracks(_ title: String, _ list: [Track], select: ((Int32) -> Void)?) -> some View {
        Menu(title) {
            ForEach(list, id: \.id) { track in
                Toggle(track.name, isOn: Binding(get: { track.selected }, set: { _ in select?(track.id) }))
            }
        }
        .disabled(list.isEmpty)
    }
}

/// A tab picked in the menu bar, for `RootView` to open.
@MainActor
@Observable
final class MacMenu {
    static let shared = MacMenu()
    var requestedTab: AppTab?

    func open(_ tab: AppTab) { requestedTab = tab }
}

/// Settings only the Mac has.
enum MacSettings {
    static let autoFullScreen = "macAutoFullScreen"
}

/// In Settings: the window goes full screen while a player shows. Off by default.
struct MacPlayerSettingsSection: View {
    @AppStorage(MacSettings.autoFullScreen) private var autoFullScreen = false

    var body: some View {
        Section {
            Toggle("Full screen when playing", isOn: $autoFullScreen)
        } footer: {
            Text("The window goes full screen when a channel or film opens, and comes back when it closes.")
        }
    }
}

enum MacWindow {
    /// Lumen's one window (SwiftUI saves its place under the `Window` scene's id).
    @MainActor static var main: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == "main" } ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    }

    /// Keeps the title bar see-through, with no line under it: the pages run up underneath.
    @MainActor static func clearTitleBar() {
        guard let main else { return }
        main.titlebarAppearsTransparent = true
        main.titlebarSeparatorStyle = .none
    }

    /// While a player fills the window its page's toolbar goes (back button, menus, and the band
    /// full screen draws behind them). AppKit's switch rather than SwiftUI's: that one also takes
    /// the close, minimise and full-screen buttons away.
    @MainActor static func updateChrome() {
        let stage = PlayerStage.shared
        clearTitleBar()
        main?.toolbar?.isVisible = stage.showing == nil || stage.isMini
    }

    /// The green button's full screen, for the player's F key and full-screen button. From the mini
    /// player it first goes back to the window.
    @MainActor static func toggleFullScreen() {
        if PlayerStage.shared.isMini { PlayerStage.shared.expand() }
        main?.toggleFullScreen(nil)
    }
}

// MARK: - Players in the window

/// macOS has no full-screen cover, so the players show here: over the whole window, above the
/// tabs and the top bar (`RootView` puts this on top), or in the mini player. `fullWindowCover`
/// hands its player over.
///
/// Each player has its own AppKit host view, which is what moves between the window and the mini
/// player: SwiftUI keeps the player inside it running, so the stream isn't reopened. Two things
/// would fire the player's `onDisappear`, which stops it, so neither may happen during a move:
/// `removeFromSuperview` (only `tearDown` does that), and SwiftUI removing the view that holds it,
/// so `holder` always stays in the window, empty when there's no player.
@MainActor
@Observable
final class PlayerStage {
    static let shared = PlayerStage()

    struct Showing {
        let id: UUID
        let host: NSHostingView<AnyView>
        let close: () -> Void
    }

    private(set) var showing: Showing?
    private(set) var isMini = false
    @ObservationIgnored private var panel: MiniPanel?
    /// The player's place in the main window (`PlayerStageLayer`).
    @ObservationIgnored let holder = PlayerHolder()
    /// "Full screen when playing": the window went full screen for the player, so it comes back
    /// when the player goes. (Full screen you chose yourself stays.)
    @ObservationIgnored private var enteredFullScreen = false

    /// The mini player's window while it's showing, for the player keys.
    var miniWindow: NSWindow? { isMini ? panel : nil }

    func show(_ view: AnyView, close: @escaping () -> Void) -> UUID {
        // The old stream stops first: providers allow one connection.
        tearDown()
        let id = UUID()
        let host = NSHostingView(rootView: AnyView(
            view.environment(\.closePlayer) { [weak self] in self?.closeCurrent() }
        ))
        // The player follows whatever holds it, and doesn't set the window's size or inset itself.
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        host.frame = holder.bounds
        holder.addSubview(host)
        showing = Showing(id: id, host: host, close: close)
        MacWindow.updateChrome()
        enterFullScreenIfWanted()
        return id
    }

    /// Its page's `fullWindowCover` was closed. In the mini player the film isn't tied to that page.
    func hide(_ id: UUID) {
        guard showing?.id == id, !isMini else { return }
        tearDown()
        leaveFullScreenIfEntered()
    }

    /// ✕ or Esc, the end of a film, or the mini player's close.
    func closeCurrent() {
        let close = showing?.close
        tearDown()
        leaveFullScreenIfEntered()
        close?()
    }

    func toggleMini() {
        if isMini { expand() } else { goMini() }
    }

    private func goMini() {
        guard let showing, !isMini else { return }
        let panel = panel ?? MiniPanel.make()
        self.panel = panel
        panel.orderFrontRegardless()
        panel.content?.hold(showing.host)
        isMini = true
        MacWindow.updateChrome()
        leaveFullScreenIfEntered()
        // Its page's cover counts as closed, so the same film can be opened again from there.
        showing.close()
    }

    /// Back in the main window, at the same point.
    func expand() {
        guard isMini, let showing else { return }
        showing.host.frame = holder.bounds
        holder.addSubview(showing.host)
        isMini = false
        MacWindow.updateChrome()
        if let main = MacWindow.main {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        panel?.orderOut(nil)
        enterFullScreenIfWanted()
    }

    private func enterFullScreenIfWanted() {
        guard UserDefaults.standard.bool(forKey: MacSettings.autoFullScreen), !isMini,
              let main = MacWindow.main, !main.styleMask.contains(.fullScreen) else { return }
        enteredFullScreen = true
        main.toggleFullScreen(nil)
    }

    private func leaveFullScreenIfEntered() {
        guard enteredFullScreen else { return }
        enteredFullScreen = false
        // You may have left full screen yourself in the meantime.
        if let main = MacWindow.main, main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
    }

    private func tearDown() {
        showing?.host.removeFromSuperview()
        showing = nil
        isMini = false
        panel?.orderOut(nil)
        MacWindow.updateChrome()
    }
}

/// `fullWindowCover` on the Mac: when `item` is set its player goes on the stage, and closing the
/// player (✕, Esc, the end of a film) sets `item` back to nil, as SwiftUI's cover would. The host
/// view starts its own SwiftUI environment, so what the players read is passed along.
struct StageCover<Item: Identifiable, Cover: View>: ViewModifier {
    @Binding var item: Item?
    let cover: (Item) -> Cover
    @State private var token: UUID?
    @Environment(PlaylistStore.self) private var store
    @Environment(\.lumenWide) private var wide
    @Environment(\.screenSize) private var screenSize

    func body(content: Content) -> some View {
        content.onChange(of: item?.id, initial: true) { _, _ in update() }
    }

    private func update() {
        if let token {
            PlayerStage.shared.hide(token)
            self.token = nil
        }
        guard let item else { return }
        let binding = $item
        let player = cover(item)
            .environment(store)
            .environment(\.lumenWide, wide)
            .environment(\.screenSize, screenSize)
            .environment(\.colorScheme, .dark)
        token = PlayerStage.shared.show(AnyView(player)) { binding.wrappedValue = nil }
    }
}

extension View {
    /// The root's top layer: whichever player is showing, filling the window.
    func playerStage() -> some View { modifier(PlayerStageLayer()) }
}

private struct PlayerStageLayer: ViewModifier {
    func body(content: Content) -> some View {
        let stage = PlayerStage.shared
        content.overlay {
            PlayerSlot(holder: stage.holder)
                // The title bar's buttons stay clickable over the picture.
                .ignoresSafeArea()
                // Empty, it mustn't take the clicks meant for the page underneath.
                .allowsHitTesting(stage.showing != nil && !stage.isMini)
        }
    }
}

/// Holds the player in the main window. It's always there, and lets clicks through when empty.
final class PlayerHolder: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        subviews.isEmpty ? nil : super.hitTest(point)
    }
}

private struct PlayerSlot: NSViewRepresentable {
    let holder: NSView
    func makeNSView(context: Context) -> NSView { holder }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The player keys (see `View.macPlayerKeys`), read from the window's key presses while the
/// player is showing. Keys with ⌘ go to the menu bar, and typing in a field is left alone.
struct MacPlayerKeys: ViewModifier {
    let handle: (PlayerKey) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.modifierFlags.contains(.command) { return event }
                    // In the mini player these keys are only for it once it's been clicked: while
                    // you browse in the main window, Space and the arrows stay yours.
                    let isMini = MainActor.assumeIsolated { PlayerStage.shared.isMini }
                    let miniWindow = MainActor.assumeIsolated { PlayerStage.shared.miniWindow }
                    if isMini, event.window !== miniWindow { return event }
                    if NSApp.keyWindow?.firstResponder is NSText { return event }
                    let key: PlayerKey?
                    switch event.keyCode {
                    case 126: key = .up
                    case 125: key = .down
                    case 123: key = .left
                    case 124: key = .right
                    case 49: key = .space
                    case 53: key = .escape
                    case 3: // F
                        MacWindow.toggleFullScreen()
                        return nil
                    default: key = nil
                    }
                    guard let key else { return event }
                    return MainActor.assumeIsolated { handle(key) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
#endif
