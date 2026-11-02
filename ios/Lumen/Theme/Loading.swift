import SwiftUI

/// Lumen's "working on it" sign everywhere, in place of the system spinner (Hayat 2026-11-02:
/// the spinning circle felt cheap). A thin line with a soft light passing through it.
/// With Reduce Motion on, the line gently brightens and dims instead.
struct LoadingLine: View {
    /// The longest it gets; it fills the width it's given up to that.
    var maxWidth: CGFloat = .infinity
    @State private var moving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Capsule()
                .fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    if !reduceMotion {
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.4)
                            // From just off the left end to just off the right end.
                            .offset(x: moving ? width : -width * 0.4)
                    }
                }
                .clipShape(Capsule())
                .opacity(reduceMotion && moving ? 0.5 : 1)
        }
        .frame(height: 3)
        .frame(maxWidth: maxWidth)
        .onAppear {
            // Unlike SwiftUI's own ProgressView, this only moves because of the repeating
            // animation started here; it stops by itself when the view goes away.
            let animation: Animation = reduceMotion
                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                : .easeInOut(duration: 1.6).repeatForever(autoreverses: false)
            withAnimation(animation) { moving = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// The screen while a film, episode or channel starts (style A from the mockups): its picture
/// drifting slowly (or, without one, a wash of `colour`), the name, a detail line, what's
/// happening ("Resuming from 42:10"), and the loading line. It fades away when the picture appears.
struct PlaybackLoading: View {
    let art: URL?
    var colour: Color = Color(red: 0.06, green: 0.09, blue: 0.18)
    let heading: String
    var detail: String?
    var status: String?

    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let art {
                CachedImage(url: art) { colourWash }
                    .scaleEffect(drift ? 1.08 : 1, anchor: .trailing)
            } else {
                colourWash
            }
            // Dark from the left and the bottom, so the text reads on any picture.
            LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.45), .black.opacity(0.12)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .bottom, endPoint: .center)

            VStack(alignment: .leading, spacing: 8) {
                Text(heading)
                    .font(LumenFont.inter(32, .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let detail {
                    Text(detail).font(LumenFont.inter(16, .medium)).lineLimit(1)
                }
                if let status {
                    Text(status).font(LumenFont.inter(15, .medium)).foregroundStyle(LumenColors.textSecondary)
                }
                LoadingLine(maxWidth: 320).padding(.top, 8)
            }
            .foregroundStyle(LumenColors.textPrimary)
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.bottom, 48)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false) // taps go through to the player's controls
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private var colourWash: some View {
        ZStack {
            colour
            RadialGradient(colors: [.white.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 700)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
    }
}
