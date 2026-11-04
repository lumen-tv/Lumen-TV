import Shared
import SwiftUI

/// A channel's picture: its logo from the tv-logos collection (found by name, see `ChannelLogos`)
/// on a deep tile of the logo's colour, or, when there's no match or the Settings switch is off,
/// a tile in a colour picked from the channel's name with the name in white.
/// (Until 2026-11-04 every channel had the name tile. The provider's own logos are never used:
/// Hayat found them inconsistent even after tidying.)
struct ChannelArt: View {
    let channel: LiveChannel
    var cornerRadius: CGFloat = 10
    @AppStorage(ChannelLogos.settingKey) private var online = true
    @State private var loaded: (key: String, result: ChannelLogos.Lookup)?

    var body: some View {
        let key = channel.key
        let title = channel.title
        GeometryReader { geo in
            ZStack {
                if let art = art(key) {
                    LogoTile(art: art, size: geo.size)
                        .transition(.opacity)
                } else {
                    NameTile(title: title, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .task(id: online ? key : "") {
            guard online, ChannelLogos.shared.cached(channel) == nil else { return }
            let result = await ChannelLogos.shared.logo(channel)
            // Fades from the name tile to the logo the first time; afterwards it's in memory
            // and shows at once.
            withAnimation(.easeOut(duration: 0.25)) { loaded = (key, result) }
        }
    }

    private func art(_ key: String) -> ChannelLogoArt? {
        guard online else { return nil }
        let result = ChannelLogos.shared.cached(channel) ?? (loaded?.key == key ? loaded?.result : nil)
        if case .logo(let art)? = result { return art }
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
