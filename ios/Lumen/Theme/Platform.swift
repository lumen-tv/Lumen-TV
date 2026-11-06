import SwiftUI

// The few things iPhone/iPad and Mac do differently, behind one name each, so the screens
// themselves stay the same code on both. (`#if os(iOS)` is Swift's compile-time switch: the
// Mac build never sees the iOS-only calls, and the reverse.)

extension View {
    /// Link fields: the keyboard with "/" and ".com" on iPhone. (A Mac has a real keyboard.)
    @ViewBuilder
    func urlKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }

    /// No capital letter at the start (logins, links, search).
    @ViewBuilder
    func noAutoCapitals() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// A small title in the bar, not iOS's big one.
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Shows or hides the page's bar (with the back button). On the Mac that's the window's
    /// toolbar, where a pushed page's back button lives.
    @ViewBuilder
    func navBar(_ visibility: Visibility) -> some View {
        #if os(iOS)
        toolbar(visibility, for: .navigationBar)
        #else
        // Mac: the window's toolbar always stays, because it holds the close / minimise / full
        // screen buttons (hiding it took them away, Hayat 2026-11-06). Pages without a bar just
        // keep it see-through; pushed pages show their back button in it.
        toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }

    /// The bar floats over the page with no background of its own.
    @ViewBuilder
    func clearNavBar() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }

    /// iPhone/iPad: the clock and battery go while a film plays. (A Mac has no status bar.)
    @ViewBuilder
    func hideStatusBar(_ hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden)
        #else
        self
        #endif
    }

    /// A menu that looks only like its own label. On the Mac a `Menu` otherwise draws a box and a
    /// chevron around it. iPhone/iPad already show just the label.
    @ViewBuilder
    func plainMenu() -> some View {
        #if os(macOS)
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        #else
        self
        #endif
    }

    /// Mac: a poster, card or tile lifts under the pointer. Nothing on iPhone/iPad.
    @ViewBuilder
    func macHoverLift() -> some View {
        #if os(macOS)
        modifier(MacHoverLift())
        #else
        self
        #endif
    }

    /// Mac: a button brightens under the pointer. Nothing on iPhone/iPad.
    @ViewBuilder
    func macHoverHighlight() -> some View {
        #if os(macOS)
        modifier(MacHoverHighlight())
        #else
        self
        #endif
    }

    /// Mac: a list row gets a faint fill under the pointer. Nothing on iPhone/iPad.
    @ViewBuilder
    func macHoverRow() -> some View {
        #if os(macOS)
        modifier(MacHoverRow())
        #else
        self
        #endif
    }

    /// Mac: < > buttons on a sideways row of posters or cards. Nothing on iPhone/iPad, where a
    /// finger scrolls it.
    @ViewBuilder
    func macRowArrows() -> some View {
        #if os(macOS)
        modifier(MacRowArrows())
        #else
        self
        #endif
    }

    /// The page zooms out of the tapped poster on iPhone/iPad. macOS has no zoom transition, so a
    /// page there just opens.
    @ViewBuilder
    func zoomOpen(from id: some Hashable, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        navigationTransition(.zoom(sourceID: id, in: namespace))
        #else
        self
        #endif
    }

    /// The players: full screen over everything on iPhone/iPad. On the Mac they fill the
    /// window (F or the green button makes the window full screen), shown by `PlayerStage`
    /// at the root, because macOS has no full-screen cover.
    @ViewBuilder
    func fullWindowCover<Item: Identifiable, Cover: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Cover
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        modifier(StageCover(item: item, cover: content))
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The right end of the bar.
    static var lumenTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

/// The size the backgrounds and backdrops are laid out against: the screen on iPhone/iPad, the
/// window on the Mac (which can be any size, so the root keeps it up to date).
private struct ScreenSizeKey: EnvironmentKey {
    static var defaultValue: CGSize {
        #if os(iOS)
        UIScreen.main.bounds.size
        #else
        CGSize(width: 1440, height: 900)
        #endif
    }
}

extension EnvironmentValues {
    var screenSize: CGSize {
        get { self[ScreenSizeKey.self] }
        set { self[ScreenSizeKey.self] = newValue }
    }
}

enum LumenPlatform {
    #if os(macOS)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// Mac: the player is in the mini player, which has its own buttons. Never on iPhone/iPad.
    @MainActor static var playerIsMini: Bool {
        #if os(macOS)
        PlayerStage.shared.isMini
        #else
        false
        #endif
    }
}

extension EnvironmentValues {
    /// Mac: closes the player showing in the window. Nil on iPhone/iPad, where the players use
    /// SwiftUI's own dismiss.
    @Entry var closePlayer: (() -> Void)? = nil
}

/// The player keys on a Mac keyboard.
enum PlayerKey { case up, down, left, right, space, escape }

extension View {
    /// Mac: `handle` gets the player keys while this view is showing (return false to let a key
    /// through). F toggles full screen by itself. Nothing on iPhone/iPad.
    @ViewBuilder
    func macPlayerKeys(_ handle: @escaping (PlayerKey) -> Bool) -> some View {
        #if os(macOS)
        modifier(MacPlayerKeys(handle: handle))
        #else
        self
        #endif
    }

    /// Mac: `moved` runs when the mouse moves over the view (to bring the controls back).
    @ViewBuilder
    func macMouseMoved(_ moved: @escaping () -> Void) -> some View {
        #if os(macOS)
        onContinuousHover { phase in
            if case .active = phase { moved() }
        }
        #else
        self
        #endif
    }
}
