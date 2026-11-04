import CoreGraphics
import ImageIO
import SwiftUI
import UIKit

/// A provider logo after `LogoCleaner` has tidied it, ready to draw.
struct TidyLogo {
    let image: UIImage
    /// The tile behind the logo.
    let tileRGB: LogoRGB
    /// A deep colour for the screen's background glow (Home's hero, the guide).
    let glowRGB: LogoRGB
    /// true = artwork that runs to its edges, drawn whole and fitted into the tile.
    let picture: Bool

    var tile: Color { Self.color(tileRGB) }
    var glow: Color { Self.color(glowRGB) }

    static func color(_ c: LogoRGB) -> Color {
        Color(.sRGB, red: Double(c.r / 255), green: Double(c.g / 255), blue: Double(c.b / 255))
    }
}

/// Downloads each channel's logo (the URL the user's own provider puts in the playlist), tidies it
/// once in the background and keeps the result: in memory, and on disk so it isn't redone after a
/// relaunch. Lumen ships no logos itself; it only shows what the provider sends.
@MainActor
final class ChannelLogos {
    static let shared = ChannelLogos()

    enum Lookup {
        case logo(TidyLogo)
        /// No usable logo (broken link, an SVG, nothing left after tidying): show the name tile.
        case missing
    }

    /// Bump when LogoCleaner changes, so logos tidied by an older version are done again.
    nonisolated private static let version = "v2"
    /// Logos are tidied at this size: sharp on the biggest tile (Home on the iPad), quick to do.
    private static let tidySize = 384
    private static let maxAtOnce = 3

    private var memory: [String: Lookup] = [:]
    private var running: [String: Task<Lookup, Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumenLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// What's already known for this URL, without waiting (nil = not looked at yet).
    func cached(_ url: String) -> Lookup? { memory[url] }

    func logo(_ url: String) async -> Lookup {
        if let hit = memory[url] { return hit }
        if let task = running[url] { return await task.value }
        let task = Task { await self.load(url) }
        running[url] = task
        let result = await task.value
        running[url] = nil
        memory[url] = result
        return result
    }

    /// The background glow for a channel: its logo's colour once known, else the name tile's.
    func glow(logoUrl: String?, title: String) -> Color {
        if let logoUrl, case .logo(let logo)? = memory[logoUrl] { return logo.glow }
        return NameTile.colour(for: title)
    }

    private func load(_ url: String) async -> Lookup {
        let file = folder.appendingPathComponent(Self.fileName(url))
        // Tidied before (this launch or an earlier one)?
        let fromDisk = await Task.detached(priority: .utility) { Self.read(file) }.value
        if let fromDisk { return fromDisk }
        guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true else { return .missing }

        await turn()
        defer { done() }
        // Downloaded through the app's picture cache (shared with posters), shrunk while decoding.
        guard let image = await ImagePipeline.shared.image(parsed, maxPixels: Self.tidySize), let cg = image.cgImage else {
            return .missing // not saved: the network may just be down right now
        }
        return await Task.detached(priority: .utility) { () -> Lookup in
            guard let logo = Self.tidy(cg) else {
                Self.write(nil, to: file)
                return Lookup.missing
            }
            Self.write(logo, to: file)
            return Lookup.logo(logo)
        }.value
    }

    /// At most a few logos are tidied at once, so a long channel list doesn't starve the app.
    private func turn() async {
        if active < Self.maxAtOnce { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func done() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }

    // MARK: - Pixels in and out

    nonisolated private static func tidy(_ cg: CGImage) -> TidyLogo? {
        var w = cg.width, h = cg.height
        // Small logos are drawn twice as big first, as in the tested prototype.
        if max(w, h) < 200 { w *= 2; h *= 2 }
        guard w >= 16, h >= 16, let px = pixels(of: cg, width: w, height: h),
              let cleaned = LogoCleaner.clean(px), let out = image(from: cleaned.pixels)
        else { return nil }
        return TidyLogo(image: UIImage(cgImage: out), tileRGB: cleaned.tile, glowRGB: cleaned.glow, picture: cleaned.mode == .picture)
    }

    /// Straight RGBA values of the picture, drawn at the given size.
    nonisolated private static func pixels(of cg: CGImage, width w: Int, height h: Int) -> LogoPixels? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let n = w * h
        var r = [Float](repeating: 0, count: n), g = r, b = r, a = r
        for i in 0..<n {
            let alpha = Float(bytes[i * 4 + 3])
            a[i] = alpha
            guard alpha > 0 else { continue }
            // CoreGraphics stores colour multiplied by alpha; LogoCleaner wants it straight.
            let k = 255 / alpha
            r[i] = min(255, Float(bytes[i * 4]) * k)
            g[i] = min(255, Float(bytes[i * 4 + 1]) * k)
            b[i] = min(255, Float(bytes[i * 4 + 2]) * k)
        }
        return LogoPixels(width: w, height: h, r: r, g: g, b: b, a: a)
    }

    nonisolated private static func image(from p: LogoPixels) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: p.count * 4)
        for i in 0..<p.count {
            let k = p.a[i] / 255
            bytes[i * 4] = UInt8(min(255, max(0, p.r[i] * k)).rounded())
            bytes[i * 4 + 1] = UInt8(min(255, max(0, p.g[i] * k)).rounded())
            bytes[i * 4 + 2] = UInt8(min(255, max(0, p.b[i] * k)).rounded())
            bytes[i * 4 + 3] = UInt8(min(255, max(0, p.a[i])).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Disk

    /// One PNG per logo plus a small text file: "tile r,g,b;glow r,g,b;logo|picture" or "none".
    nonisolated private static func fileName(_ url: String) -> String {
        // FNV-1a: stable across launches (Swift's hashValue isn't).
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (version + url).utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    nonisolated private static func read(_ base: URL) -> Lookup? {
        guard let info = try? String(contentsOf: base.appendingPathExtension("txt"), encoding: .utf8) else { return nil }
        if info == "none" { return Lookup.missing }
        let parts = info.split(separator: ";").map(String.init)
        guard parts.count == 3, let tile = rgb(parts[0]), let glow = rgb(parts[1]),
              let data = try? Data(contentsOf: base.appendingPathExtension("png")), let image = UIImage(data: data)
        else { return nil }
        return .logo(TidyLogo(image: image, tileRGB: tile, glowRGB: glow, picture: parts[2] == "picture"))
    }

    nonisolated private static func write(_ logo: TidyLogo?, to base: URL) {
        guard let logo else {
            try? "none".write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            return
        }
        guard let png = logo.image.pngData() else { return }
        try? png.write(to: base.appendingPathExtension("png"), options: .atomic)
        let info = "\(text(logo.tileRGB));\(text(logo.glowRGB));\(logo.picture ? "picture" : "logo")"
        try? info.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    nonisolated private static func text(_ c: LogoRGB) -> String {
        "\(Int(c.r.rounded())),\(Int(c.g.rounded())),\(Int(c.b.rounded()))"
    }

    nonisolated private static func rgb(_ s: String) -> LogoRGB? {
        let v = s.split(separator: ",").compactMap { Float($0) }
        return v.count == 3 ? LogoRGB(r: v[0], g: v[1], b: v[2]) : nil
    }
}

/// A tidied logo on its tile.
struct LogoTile: View {
    let logo: TidyLogo
    let size: CGSize

    var body: some View {
        ZStack {
            logo.tile
            // A little light at the top and shade at the bottom, as on the name tiles.
            LinearGradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.13)], startPoint: .top, endPoint: .bottom)
            if logo.picture {
                // Whole artwork as a small rounded card, about the same size as the other logos.
                let fit = Self.fit(logo.image.size, in: size, area: 0.36, maxWidth: 0.80, maxHeight: 0.70)
                Image(uiImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: fit.height * 0.1, style: .continuous))
            } else {
                let fit = Self.fit(logo.image.size, in: size)
                Image(uiImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Every logo gets about the same visual weight: 30% of the tile's area, but never wider than
    /// 74% or taller than 60% of it (so wide wordmarks and square badges look equally big).
    static func fit(_ image: CGSize, in tile: CGSize, area: CGFloat = 0.30, maxWidth: CGFloat = 0.74, maxHeight: CGFloat = 0.60) -> CGSize {
        guard image.width > 0, image.height > 0, tile.width > 0, tile.height > 0 else { return .zero }
        let aspect = image.width / image.height
        var h = (area * tile.width * tile.height / aspect).squareRoot()
        var w = h * aspect
        let s = min(1, maxWidth * tile.width / w, maxHeight * tile.height / h)
        w *= s; h *= s
        return CGSize(width: w, height: h)
    }
}
