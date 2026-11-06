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

enum MacWindow {
    /// Lumen's one window (SwiftUI saves its place under the `Window` scene's id).
    @MainActor static var main: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == "main" } ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
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
/// player: SwiftUI keeps the player inside it running, so the stream isn't reopened. It has to be
/// handed over with a direct `addSubview`: `removeFromSuperview` ends the player (`tearDown`).
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
        withAnimation(.easeOut(duration: 0.2)) { showing = Showing(id: id, host: host, close: close) }
        return id
    }

    /// Its page's `fullWindowCover` was closed. In the mini player the film isn't tied to that page.
    func hide(_ id: UUID) {
        guard showing?.id == id, !isMini else { return }
        tearDown()
    }

    /// ✕ or Esc, the end of a film, or the mini player's close.
    func closeCurrent() {
        let close = showing?.close
        tearDown()
        close?()
    }

    func toggleMini() {
        if isMini { expand() } else { goMini() }
    }

    private func goMini() {
        guard let showing, !isMini else { return }
        let panel = panel ?? MiniPanel.make()
        self.panel = panel
        panel.content?.hold(showing.host)
        panel.orderFrontRegardless()
        isMini = true
        // Its page's cover counts as closed, so the same film can be opened again from there.
        showing.close()
    }

    /// Back in the main window, at the same point (`PlayerStageLayer` takes the host view).
    func expand() {
        guard isMini else { return }
        isMini = false
        if let main = MacWindow.main {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        panel?.orderOut(nil)
    }

    private func tearDown() {
        showing?.host.removeFromSuperview()
        showing = nil
        isMini = false
        panel?.orderOut(nil)
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
        content.overlay {
            if let showing = PlayerStage.shared.showing, !PlayerStage.shared.isMini {
                PlayerSlot(host: showing.host)
                    .id(showing.id)
                    .transition(.opacity)
                    // The title bar's buttons stay clickable over the picture.
                    .ignoresSafeArea()
            }
        }
    }
}

/// Where the player's host view sits in the main window.
private struct PlayerSlot: NSViewRepresentable {
    let host: NSView

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        hold(in: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if host.superview !== view { hold(in: view) }
    }

    private func hold(in view: NSView) {
        host.frame = view.bounds
        view.addSubview(host)
    }
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
