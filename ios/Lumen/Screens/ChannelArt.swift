import SwiftUI

/// A channel's picture. The logo the user's provider sends for the channel, tidied by
/// `ChannelLogos` (box removed, one size, on a tile of its own colour), or, when there's no
/// usable logo, a tile in a deep colour picked from the channel's name with the name in white.
/// (Until 2026-11-04 every channel had the name tile: raw provider logos came small, stretched
/// and boxed. Hayat chose the tidied logos after seeing them on 550 real provider logos.)
struct ChannelArt: View {
    let logoUrl: String?
    let title: String
    var cornerRadius: CGFloat = 10
    @State private var loaded: (url: String, result: ChannelLogos.Lookup)?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let logo = current {
                    LogoTile(logo: logo, size: geo.size)
                        .transition(.opacity)
                } else {
                    NameTile(title: title, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .task(id: logoUrl) {
            guard let logoUrl, !logoUrl.isEmpty, ChannelLogos.shared.cached(logoUrl) == nil else { return }
            let result = await ChannelLogos.shared.logo(logoUrl)
            // Fades from the name tile to the logo the first time; afterwards it's in memory
            // and shows at once.
            withAnimation(.easeOut(duration: 0.25)) { loaded = (logoUrl, result) }
        }
    }

    private var current: TidyLogo? {
        guard let logoUrl else { return nil }
        let result = ChannelLogos.shared.cached(logoUrl) ?? (loaded?.url == logoUrl ? loaded?.result : nil)
        if case .logo(let logo)? = result { return logo }
        return nil
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
