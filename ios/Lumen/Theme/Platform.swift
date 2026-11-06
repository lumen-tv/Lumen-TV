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
        toolbar(visibility, for: .windowToolbar)
        #endif
    }

    /// The bar floats over the page with no background of its own.
    @ViewBuilder
    func clearNavBar() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        toolbarBackground(.hidden, for: .windowToolbar)
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
