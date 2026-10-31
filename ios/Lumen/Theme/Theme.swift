import SwiftUI

/// The same palette as the TV app (`LumenColors` in the Android code): dark, a softly coloured
/// ambient background, frosted glass for bars and panels, blue only as a small accent.
enum LumenColors {
    static let background = Color(hex: 0x0D0F14)
    static let surface = Color(hex: 0x1E2129)

    static let glass = Color.white.opacity(0.07)
    static let glassStrong = Color.white.opacity(0.13)
    static let glassEdge = Color.white.opacity(0.10)

    static let ambientCool = Color(hex: 0x26406E)
    static let ambientWarm = Color(hex: 0x5C3B1F)

    static let textPrimary = Color(hex: 0xF5F5F7)
    static let textSecondary = Color(hex: 0xA1A1A6)
    static let textTertiary = Color(hex: 0x6E6E73)

    static let accent = Color(hex: 0x0A84FF)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Inter, bundled in Resources/Fonts (OFL, see third_party/inter), as on the TV.
enum LumenFont {
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size).weight(weight)
    }

    static let largeTitle = inter(32, .semibold)
    static let title = inter(22, .semibold)
    static let headline = inter(17, .semibold)
    static let body = inter(16)
    static let caption = inter(13, .medium)
}

/// The dark background with two big soft glows (cool top left, warm bottom right), so screens
/// aren't flat black. Same idea as `Ambient` in the TV app.
struct AmbientBackground: View {
    var tint: Color = LumenColors.ambientCool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                LumenColors.background
                RadialGradient(
                    colors: [tint.opacity(0.55), tint.opacity(0.18), .clear],
                    center: UnitPoint(x: 0.15, y: 0),
                    startRadius: 0, endRadius: max(w, 400) * 0.8
                )
                RadialGradient(
                    colors: [LumenColors.ambientWarm.opacity(0.40), LumenColors.ambientWarm.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.9, y: 1),
                    startRadius: 0, endRadius: max(w, 400) * 0.7
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.7), value: tint)
    }
}

extension View {
    /// Frosted glass, like `Modifier.glass()` on the TV: a light translucent fill and a faint edge.
    /// (On iPhone a real `.ultraThinMaterial` blur would be affordable too; the flat fill keeps
    /// both apps looking the same.)
    func glass(cornerRadius: CGFloat = 20, fill: Color = LumenColors.glass) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LumenColors.glassEdge, lineWidth: 1)
            )
    }
}

/// The white pill (Play, Add playlist): white with dark text, as focus looks on the TV.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LumenFont.headline)
            .foregroundStyle(LumenColors.background)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.white, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// The glass pill for everything else.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LumenFont.headline)
            .foregroundStyle(LumenColors.textPrimary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .glass(cornerRadius: 999, fill: configuration.isPressed ? LumenColors.glassStrong : LumenColors.glass)
    }
}

/// A small round glass button with an SF Symbol (search, close, back).
struct CircleGlassButton: View {
    let systemImage: String
    var label: String
    var size: CGFloat = 40
    var fill: Color = LumenColors.glass
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(LumenColors.textPrimary)
                .frame(width: size, height: size)
                .glass(cornerRadius: size / 2, fill: fill)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A filter pill (categories, All / Films / Series, seasons): white when chosen, glass otherwise.
struct ChipButton: View {
    let title: String
    let selected: Bool
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LumenFont.inter(large ? 16 : 14, .medium))
                .foregroundStyle(selected ? LumenColors.background : LumenColors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, large ? 18 : 14)
                .padding(.vertical, large ? 10 : 8)
                .background(selected ? Color.white : Color.clear, in: Capsule())
                .glass(cornerRadius: 999, fill: selected ? .clear : LumenColors.glass)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

/// A thin progress bar (programme or film progress).
struct ProgressLine: View {
    let fraction: Double
    var height: CGFloat = 4
    var track: Color = .white.opacity(0.25)

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(track).overlay(alignment: .leading) {
                Capsule().fill(.white).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// "7:31 PM" over "Thursday 29 October", top right on iPad as on the TV.
struct ClockView: View {
    var body: some View {
        // TimelineView redraws on the minute; SwiftUI has no Compose-style ticking state for this.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(LumenFont.inter(24, .semibold))
                    .foregroundStyle(LumenColors.textPrimary)
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(LumenFont.caption)
                    .foregroundStyle(LumenColors.textSecondary)
            }
        }
    }
}

/// Section title with an optional line of help next to it ("Favourites   Hold to move or remove").
struct SectionTitle: View {
    let title: String
    var hint: String?
    var tag: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(LumenFont.title).foregroundStyle(LumenColors.textPrimary)
            if let tag { QualityTag(text: tag) }
            if let hint {
                Spacer(minLength: 8)
                Text(hint).font(LumenFont.caption).foregroundStyle(LumenColors.textSecondary).lineLimit(1)
            }
        }
    }
}

extension EnvironmentValues {
    /// True on a full-width iPad window: the TV-like layout (top pill, wider grids). False on
    /// iPhone and in narrow iPad split-screen windows, which get the one-column phone layout.
    @Entry var lumenWide = false
    /// Opens the search screen (films, series and channels) from any tab.
    @Entry var openSearch: () -> Void = {}
}

/// Side padding: 20 on iPhone, 48 on iPad (the TV's safe area is 48 too).
extension View {
    func lumenGutter(_ wide: Bool) -> some View { padding(.horizontal, wide ? 48 : 20) }
}

extension View {
    /// iOS 26 blurs and dims scroll content under the status bar ("scroll edge effect"). With
    /// Lumen's coloured backgrounds that showed as a band with a hard line under the clock, so
    /// it's turned off everywhere. (`#if compiler` keeps this building on Xcode 16 too.)
    @ViewBuilder
    func hideTopScrollEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
