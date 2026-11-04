import CoreGraphics
import Shared
import SwiftUI
import UIKit

/// A channel logo from tv-logos, ready to draw.
struct ChannelLogoArt {
    let image: UIImage
    /// The tile behind the logo: a deep version of the logo's main colour.
    let tile: Color
}

/// Channel logos from github.com/tv-logo/tv-logos (community collection, CC BY-SA / BY-NC-SA; the logos are
/// their owners' trademarks). Lumen ships only the list of its file names; each channel's logo is
/// found by name (`TvLogoIndex`) and downloaded when first shown, through the app's picture cache.
/// The provider's own logo URLs aren't used (Hayat 2026-11-04: they look inconsistent even tidied).
/// Channels with no match keep the name tile. Settings → Channel logos turns this off.
@MainActor
final class ChannelLogos {
    static let shared = ChannelLogos()
    /// UserDefaults key of the Settings switch (on unless turned off).
    static let settingKey = "onlineChannelLogos"
    static let base = "https://raw.githubusercontent.com/tv-logo/tv-logos/main/"

    enum Lookup {
        case logo(ChannelLogoArt)
        case missing
    }

    private var index: TvLogoIndex?
    private var loadingIndex: Task<TvLogoIndex, Never>?
    private var memory: [String: Lookup] = [:]
    private var running: [String: Task<Lookup, Never>] = [:]

    private init() {}

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// What's known for this channel already, without waiting (nil = not looked up yet).
    func cached(_ channel: LiveChannel) -> Lookup? { memory[channel.key] }

    func logo(_ channel: LiveChannel) async -> Lookup {
        let id = channel.key
        if let hit = memory[id] { return hit }
        if let task = running[id] { return await task.value }
        let title = channel.title, raw = channel.name, category = channel.categoryName
        let task = Task { await self.load(title: title, raw: raw, category: category) }
        running[id] = task
        let result = await task.value
        running[id] = nil
        memory[id] = result
        return result
    }

    /// The background glow for a channel: its logo's tile colour once known, else the name tile's.
    func glow(_ channel: LiveChannel) -> Color {
        if Self.enabled, case .logo(let art)? = memory[channel.key] { return art.tile }
        return NameTile.colour(for: channel.title)
    }

    private func load(title: String, raw: String, category: String?) async -> Lookup {
        let index = await loadIndex()
        let region = Locale.current.region?.identifier
        guard let path = index.match(title: title, rawName: raw, category: category, region: region),
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: Self.base + encoded)
        else { return .missing }
        guard let image = await ImagePipeline.shared.image(url, maxPixels: 480) else {
            return .missing
        }
        let tile = await Task.detached(priority: .utility) { Self.tileColour(image) }.value
        return .logo(ChannelLogoArt(image: image, tile: tile))
    }

    private func loadIndex() async -> TvLogoIndex {
        if let index { return index }
        if let loadingIndex { return await loadingIndex.value }
        let task = Task.detached(priority: .utility) { () -> TvLogoIndex in
            let url = Bundle.main.url(forResource: "tv-logos-index", withExtension: "txt")
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            return TvLogoIndex(text: text)
        }
        loadingIndex = task
        let loaded = await task.value
        index = loaded
        return loaded
    }

    /// A deep version of the logo's main colour (tv-logos draws its logos for dark backgrounds),
    /// or a neutral slate for white/grey logos.
    nonisolated private static func tileColour(_ image: UIImage) -> Color {
        let slate = Color(red: 40 / 255, green: 44 / 255, blue: 56 / 255)
        guard let cg = image.cgImage else { return slate }
        let side = 24
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return slate }
        var hist = [Double](repeating: 0, count: 24)
        var sats: [Double] = []
        var visible = 0
        for i in 0..<(side * side) {
            let a = Double(px[i * 4 + 3])
            guard a > 200 else { continue }
            visible += 1
            // Colours are stored multiplied by alpha: divide it back out (0…1).
            let r = Double(px[i * 4]) / a, g = Double(px[i * 4 + 1]) / a, b = Double(px[i * 4 + 2]) / a
            let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
            guard mx > mn else { continue }
            let d = mx - mn
            let s = l <= 0.5 ? d / (mx + mn) : d / (2 - mx - mn)
            guard s > 0.3, l > 0.12, l < 0.88 else { continue }
            var h = mx == r ? (g - b) / d : (mx == g ? 2 + (b - r) / d : 4 + (r - g) / d)
            h = (h / 6).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            hist[min(23, Int(h * 24))] += s
            sats.append(s)
        }
        guard visible > 0, Double(sats.count) > 0.1 * Double(visible) else { return slate }
        let bin = hist.indices.max { hist[$0] < hist[$1] }!
        sats.sort()
        return Color(hue: (Double(bin) + 0.5) / 24, saturation: min(0.75, sats[sats.count / 2]), brightness: 0.30)
    }
}

/// A tv-logos logo centred on its tile.
struct LogoTile: View {
    let art: ChannelLogoArt
    let size: CGSize

    var body: some View {
        let fit = Self.fit(art.image.size, in: size)
        ZStack {
            art.tile
            // A little light at the top and shade at the bottom, as on the name tiles.
            LinearGradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.13)], startPoint: .top, endPoint: .bottom)
            Image(uiImage: art.image)
                .resizable()
                .interpolation(.high)
                .frame(width: fit.width, height: fit.height)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Every logo gets about the same visual weight: 30% of the tile's area, but never wider than
    /// 74% or taller than 60% of it (so wide wordmarks and square badges look equally big).
    static func fit(_ image: CGSize, in tile: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, tile.width > 0, tile.height > 0 else { return .zero }
        let aspect = image.width / image.height
        var h = (0.30 * tile.width * tile.height / aspect).squareRoot()
        var w = h * aspect
        let s = min(1, 0.74 * tile.width / w, 0.60 * tile.height / h)
        w *= s; h *= s
        return CGSize(width: w, height: h)
    }
}
