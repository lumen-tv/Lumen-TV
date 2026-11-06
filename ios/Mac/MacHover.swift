#if os(macOS)
import SwiftUI

// What a mouse adds to the shared screens: things respond when the pointer is over them, and the
// sideways rows get arrows (a mouse wheel can't scroll sideways). Reached through `macHoverLift`,
// `macHoverHighlight` and `macRowArrows` in Theme/Platform.swift.

/// Posters, cards and tiles lift a little under the pointer.
struct MacHoverLift: ViewModifier {
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(over ? 1.04 : 1)
            .brightness(over ? 0.04 : 0)
            .shadow(color: .black.opacity(over ? 0.55 : 0), radius: 16, y: 8)
            .zIndex(over ? 1 : 0) // above its neighbours while bigger
            .animation(.easeOut(duration: 0.15), value: over)
            .onHover { over = $0 }
    }
}

/// Buttons brighten slightly under the pointer.
struct MacHoverHighlight: ViewModifier {
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .brightness(over ? 0.08 : 0)
            .scaleEffect(over ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: over)
            .onHover { over = $0 }
    }
}

/// Channel rows get a faint fill under the pointer.
struct MacHoverRow: ViewModifier {
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(over ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .animation(.easeOut(duration: 0.15), value: over)
            .onHover { over = $0 }
    }
}

/// Round < > buttons at the ends of a sideways row while the pointer is over it. Each moves about
/// a page; each one hides at its end of the row.
struct MacRowArrows: ViewModifier {
    private struct Metrics: Equatable {
        var offset: CGFloat = 0
        var least: CGFloat = 0
        var most: CGFloat = 0
        var page: CGFloat = 0
    }

    @State private var position = ScrollPosition(edge: .leading)
    @State private var metrics = Metrics()
    @State private var over = false

    func body(content: Content) -> some View {
        content
            // A lifted poster would otherwise be cut off by the row's edges.
            .scrollClipDisabled()
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(
                    offset: geometry.contentOffset.x,
                    least: -geometry.contentInsets.leading,
                    most: geometry.contentSize.width + geometry.contentInsets.trailing - geometry.containerSize.width,
                    page: geometry.containerSize.width
                )
            } action: { _, new in
                metrics = new
            }
            .overlay(alignment: .leading) {
                if over, metrics.offset > metrics.least + 2 { arrow(-1) }
            }
            .overlay(alignment: .trailing) {
                if over, metrics.offset < metrics.most - 2 { arrow(1) }
            }
            .animation(.easeOut(duration: 0.15), value: over)
            .onHover { over = $0 }
    }

    private func arrow(_ direction: CGFloat) -> some View {
        Button {
            let target = metrics.offset + direction * metrics.page * 0.85
            let clamped = min(max(target, metrics.least), max(metrics.most, metrics.least))
            withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(x: clamped) }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .playerGlass(Circle())
        .padding(.horizontal, 12)
        .transition(.opacity)
        .accessibilityLabel(direction < 0 ? "Scroll back" : "Scroll forward")
    }
}
#endif
