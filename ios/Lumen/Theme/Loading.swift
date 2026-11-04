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

/// The screen while a film, episode or channel starts (Hayat 2026-11-02: style A's layout over
/// style C's background): the colours of its picture, blurred into a soft wash that drifts slowly
/// (or, without a picture, a wash of `colour`), the name, a detail line, what's happening, centred,
/// ("Resuming from 42:10"), and the loading line. It fades away when the picture appears.
struct PlaybackLoading: View {
    let art: URL?
    var colour: Color = Color(red: 0.06, green: 0.09, blue: 0.18)
    let heading: String
    var detail: String?
    var status: String?

    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
            if let art {
                GeometryReader { geo in
                    // A small copy of the picture, blurred and scaled up to fill the screen: just
                    // its colours, no shapes, and cheap (blurring the full-size picture isn't).
                    let small = CGSize(width: 96, height: 54)
                    let fill = max(geo.size.width / small.width, geo.size.height / small.height) * 1.4
                    CachedImage(url: art) { colourWash }
                        .frame(width: small.width, height: small.height)
                        .blur(radius: 9)
                        .saturation(1.25)
                        .scaleEffect(fill * (drift ? 1.12 : 1))
                        .offset(x: drift ? -geo.size.width * 0.04 : 0)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                Color.black.opacity(0.25)
            } else {
                colourWash
            }
            // An even dim, so the text reads on any colours.
            Color.black.opacity(0.3)

            // Big, in the middle of the screen (Hayat 2026-11-02).
            VStack(spacing: 10) {
                Text(heading)
                    .font(LumenFont.inter(44, .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                if let detail {
                    Text(detail).font(LumenFont.inter(19, .medium)).multilineTextAlignment(.center).lineLimit(2)
                }
                if let status {
                    Text(status).font(LumenFont.inter(17, .medium)).foregroundStyle(LumenColors.textSecondary)
                }
                LoadingLine(maxWidth: 360).padding(.top, 14)
            }
            .foregroundStyle(LumenColors.textPrimary)
            .frame(maxWidth: 640)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
