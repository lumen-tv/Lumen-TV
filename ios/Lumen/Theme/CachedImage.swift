import ImageIO
import SwiftUI
import UIKit

/// Posters and backdrops. SwiftUI's own `AsyncImage` keeps nothing in memory: a poster that
/// scrolled out of a row and back was fetched and decoded again, at full size, on the main
/// thread, which made the poster rows stutter. This keeps the pictures in memory, shrunk to the
/// size they're shown at, and does the decoding in the background.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    /// Decoded pictures; iOS empties it by itself when memory runs low.
    private let memory = NSCache<NSString, UIImage>()
    /// Downloads, with their own disk cache, so pictures also survive a relaunch.
    private let session: URLSession
    /// One download per picture, however many views ask for it at once.
    private var running: [NSString: Task<UIImage?, Never>] = [:]

    private init() {
        memory.totalCostLimit = 150 * 1024 * 1024 // bytes of decoded pixels
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumenImages", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024, directory: folder)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    /// Sizes are rounded up to steps of 160 px, so a poster shown at nearly the same size in two
    /// places is kept once.
    nonisolated static func bucket(_ pixels: CGFloat) -> Int {
        max(160, Int((pixels / 160).rounded(.up)) * 160)
    }

    func cached(_ url: URL, maxPixels: Int) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixels))
    }

    func image(_ url: URL, maxPixels: Int) async -> UIImage? {
        let key = Self.key(url, maxPixels)
        if let hit = memory.object(forKey: key) { return hit }
        if let task = running[key] { return await task.value }
        let session = session
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixels: maxPixels)
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image, let cg = image.cgImage {
            memory.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    private static func key(_ url: URL, _ maxPixels: Int) -> NSString {
        "\(maxPixels)|\(url.absoluteString)" as NSString
    }

    /// Decodes straight to the wanted size (ImageIO never builds the full-size bitmap).
    nonisolated private static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, here in the background, not later when it's first drawn.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A picture filling the space it's given (scaled to fill and cropped), with `placeholder`
/// until it has loaded or when it can't be loaded. With `shimmer`, a soft light sweeps over a
/// plain tile while it loads (as in Apple's apps), and `placeholder` shows only if it fails.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var shimmer = false
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.displayScale) private var scale
    @State private var loaded: (url: URL, pixels: Int, image: UIImage)?
    /// The picture that couldn't be loaded (bad link, offline), so the placeholder shows.
    @State private var failed: URL?

    var body: some View {
        GeometryReader { geo in
            let pixels = ImagePipeline.bucket(max(geo.size.width, geo.size.height) * scale)
            let (image, sharp) = current(pixels)
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if shimmer, let url, failed != url {
                    Shimmer()
                } else {
                    placeholder()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: Request(url: url, pixels: pixels)) {
                guard let url, geo.size.width > 0, !sharp else { return }
                if let fetched = await ImagePipeline.shared.image(url, maxPixels: pixels) {
                    // Fades in, as in Apple's apps, instead of popping in. (A picture already in
                    // memory skips this and shows at once.)
                    withAnimation(.easeOut(duration: 0.25)) { loaded = (url, pixels, fetched) }
                } else if loaded?.url != url {
                    withAnimation(.easeOut(duration: 0.25)) { failed = url }
                }
            }
        }
    }

    /// The picture for this URL: one already in memory (so a poster scrolling back into a row
    /// shows at once, without a flash of the placeholder) or the one this view loaded. `sharp` is
    /// false when it's smaller than needed now (the view grew), so a bigger one gets loaded.
    private func current(_ pixels: Int) -> (UIImage?, sharp: Bool) {
        guard let url else { return (nil, true) }
        if let hit = ImagePipeline.shared.cached(url, maxPixels: pixels) { return (hit, true) }
        if let loaded, loaded.url == url { return (loaded.image, loaded.pixels >= pixels) }
        return (nil, false)
    }

    private struct Request: Equatable {
        let url: URL?
        let pixels: Int
    }
}

/// A loading tile: faint glass with a band of light drifting across it, left to right, every
/// 1.4 s. With Reduce Motion it just breathes softly instead.
struct Shimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let band = max(geo.size.width, 80) * 0.8
            Rectangle()
                .fill(Color.white.opacity(reduceMotion ? 0.05 + 0.04 * phase : 0.06))
                .overlay(alignment: .leading) {
                    if !reduceMotion {
                        LinearGradient(colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            // From fully off the left edge to fully off the right one.
                            .offset(x: -band + (geo.size.width + band) * phase)
                    }
                }
                .clipped()
        }
        .onAppear {
            let animation = reduceMotion
                ? Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                : Animation.linear(duration: 1.4).repeatForever(autoreverses: false)
            withAnimation(animation) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}
