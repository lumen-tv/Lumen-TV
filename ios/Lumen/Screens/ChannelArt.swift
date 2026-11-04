import SwiftUI

/// A channel's picture: always a tile in a deep colour picked from the channel's name, with the
/// name in white (the "A" style chosen 2026-10-30). Provider logos aren't used: Hayat wants every
/// channel to look consistent, and provider logos come too small or stretched. `logoUrl` is kept
/// so callers don't change if that's revisited.
struct ChannelArt: View {
    let logoUrl: String?
    let title: String
    var cornerRadius: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            NameTile(title: title, height: geo.size.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// The coloured tile with the channel's name centred in white.
struct NameTile: View {
    let title: String
    let height: CGFloat

    var body: some View {
        let colour = NameTile.colour(for: title)
        ZStack {
            colour
            // A little light at the top and shade at the bottom, as in the mockup.
            LinearGradient(
                colors: [.white.opacity(0.10), .clear, .black.opacity(0.18)],
                startPoint: .top, endPoint: .bottom
            )
            Text(title)
                .font(LumenFont.inter(max(11, height * 0.26), .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, height * 0.14)
        }
    }

    private static let palette: [UInt32] = [
        0x8E2A33, 0x1F6F6A, 0x274B8F, 0x5A3A8E, 0x80306E, 0x2E6B45, 0x8A5A24, 0x3A4658,
    ]

    /// The same name always gets the same colour (FNV-1a hash of the lowercased name;
    /// Swift's own hashValue changes on every launch, so it can't be used).
    static func colour(for title: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in title.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Color(hex: palette[Int(hash % UInt32(palette.count))])
    }
}
