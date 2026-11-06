#if os(macOS)
import AppKit
import SwiftUI

/// Lumen is one window: closing it quits, as with other single-window Mac apps.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
    /// The green button's full screen, for the player's F key.
    @MainActor static func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }
}

// MARK: - Players in the window

/// macOS has no full-screen cover, so the players show here: over the whole window, above the
/// tabs and the top bar (`RootView` puts this on top). `fullWindowCover` hands its player over.
@MainActor
@Observable
final class PlayerStage {
    static let shared = PlayerStage()

    struct Showing {
        let id: UUID
        let view: AnyView
        let close: () -> Void
    }

    private(set) var showing: Showing?

    func show(_ view: AnyView, close: @escaping () -> Void) -> UUID {
        let id = UUID()
        withAnimation(.easeOut(duration: 0.2)) { showing = Showing(id: id, view: view, close: close) }
        return id
    }

    func hide(_ id: UUID) {
        guard showing?.id == id else { return }
        withAnimation(.easeOut(duration: 0.2)) { showing = nil }
    }
}

/// `fullWindowCover` on the Mac: when `item` is set its player goes on the stage, and closing the
/// player (✕, Esc, the end of a film) sets `item` back to nil, as SwiftUI's cover would.
struct StageCover<Item: Identifiable, Cover: View>: ViewModifier {
    @Binding var item: Item?
    let cover: (Item) -> Cover
    @State private var token: UUID?

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
        token = PlayerStage.shared.show(AnyView(cover(item))) { binding.wrappedValue = nil }
    }
}

extension View {
    /// The root's top layer: whichever player is showing, filling the window.
    func playerStage() -> some View { modifier(PlayerStageLayer()) }
}

private struct PlayerStageLayer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay {
            if let showing = PlayerStage.shared.showing {
                showing.view
                    .environment(\.closePlayer, showing.close)
                    .id(showing.id)
                    .transition(.opacity)
                    // The title bar's buttons stay clickable over the picture.
                    .ignoresSafeArea()
            }
        }
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
