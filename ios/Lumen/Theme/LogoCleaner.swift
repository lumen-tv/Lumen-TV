import Foundation

// Tidies a channel logo as the provider sends it, so every logo sits the same way on a tile of its
// own colour: empty edges trimmed, any white/black/coloured box taken off (also inside letters, like
// the middle of BBC Two's "O"), black text that would vanish on a dark tile turned white, and a
// tile colour that keeps the logo readable. Plain Swift on pixel arrays (no UIKit), so it can be
// tested anywhere; `ChannelLogos.swift` feeds it pictures and caches what comes out.
//
// Tested on 550 logos from iptv-org's list (the ones providers really use), 2026-11-04.

/// Straight (not premultiplied) RGBA pixels, each value 0…255.
struct LogoPixels {
    var width: Int
    var height: Int
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var a: [Float]

    init(width: Int, height: Int, r: [Float], g: [Float], b: [Float], a: [Float]) {
        self.width = width; self.height = height; self.r = r; self.g = g; self.b = b; self.a = a
    }

    var count: Int { width * height }

    func cropped(x0: Int, y0: Int, x1: Int, y1: Int) -> LogoPixels {
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var out = LogoPixels(width: w, height: h, r: [], g: [], b: [], a: [])
        out.r.reserveCapacity(w * h); out.g.reserveCapacity(w * h); out.b.reserveCapacity(w * h); out.a.reserveCapacity(w * h)
        for y in y0...y1 {
            for x in x0...x1 {
                let i = y * width + x
                out.r.append(r[i]); out.g.append(g[i]); out.b.append(b[i]); out.a.append(a[i])
            }
        }
        return out
    }
}

/// An RGB colour, each value 0…255.
struct LogoRGB: Equatable {
    var r: Float
    var g: Float
    var b: Float
}

struct CleanedLogo {
    enum Mode {
        /// The tidied logo, to draw centred on the tile at a standard size.
        case logo
        /// Artwork that runs to its edges (a photo, a gradient): drawn whole, fitted into the tile.
        case picture
    }

    var pixels: LogoPixels
    var tile: LogoRGB
    /// A deep colour for the screen's background glow (the tile itself may be a light pastel).
    var glow: LogoRGB
    var mode: Mode
}

enum LogoCleaner {
    static let slate = LogoRGB(r: 40, g: 44, b: 56)
    static let lightGrey = LogoRGB(r: 226, g: 228, b: 234)

    /// nil = nothing usable (empty, tiny or unreadable): the caller shows the name tile.
    static func clean(_ input: LogoPixels) -> CleanedLogo? {
        var p = input
        let w = p.width, h = p.height
        guard w >= 16, h >= 16 else { return nil }

        var tile: LogoRGB?
        var transparent = true
        var boxKept = false

        // 1. What's around the edge: transparency, or a box colour?
        let edge = borderIndices(w, h, thickness: 3)
        let clearEdge = Float(edge.filter { p.a[$0] < 40 }.count) / Float(edge.count)
        if clearEdge < 0.25 {
            transparent = false
            let opaque = edge.filter { p.a[$0] > 200 }
            guard opaque.count >= 10 else { return nil }
            // The most common colour (in steps of 24), then the median of those pixels.
            var bins: [Int: [Int]] = [:]
            for i in opaque {
                let key = Int(p.r[i] / 24) * 10000 + Int(p.g[i] / 24) * 100 + Int(p.b[i] / 24)
                bins[key, default: []].append(i)
            }
            let seed = bins.max { $0.value.count < $1.value.count }!.value
            let bg = LogoRGB(r: median(seed.map { p.r[$0] }), g: median(seed.map { p.g[$0] }), b: median(seed.map { p.b[$0] }))
            let share = Float(opaque.filter { dist(p, $0, bg) < 40 }.count) / Float(opaque.count)
            if share < 0.45 {
                // Artwork running to the edges (blocks, gradients, photos): show the whole picture.
                return picture(input)
            }
            let before = Float(p.a.filter { $0 > 128 }.count)
            removeBox(&p, bg)
            let bgHls = hls(bg.r / 255, bg.g / 255, bg.b / 255)
            let lightBox = bgHls.l > 0.80 || (bgHls.s < 0.12 && bgHls.l > 0.55)
            if !lightBox && Float(p.a.filter { $0 > 128 }.count) < 0.03 * before {
                // The "box" was really most of the logo.
                return picture(input)
            }
            if !lightBox { tile = bg; boxKept = true }
        }

        // 2. Trim to what's visible.
        var x0 = w, y0 = h, x1 = -1, y1 = -1, visible = 0
        for y in 0..<h {
            for x in 0..<w where p.a[y * w + x] > 28 {
                visible += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard visible >= 30 else { return nil }
        p = p.cropped(x0: x0, y0: y0, x1: x1, y1: y1)
        guard max(p.width, p.height) >= 40 else { return nil }

        // 3. The logo's main colour.
        var vis = (0..<p.count).filter { p.a[$0] > 200 }
        if vis.count < 20 { vis = (0..<p.count).filter { p.a[$0] > 60 } }
        guard !vis.isEmpty else { return nil }
        let sample = stride(vis, max: 3000)
        let sampleHls = sample.map { hls(p.r[$0] / 255, p.g[$0] / 255, p.b[$0] / 255) }
        let colourful = sampleHls.map { $0.s > 0.30 && $0.l > 0.12 && $0.l < 0.88 }
        var hue: Float?
        var sat: Float = 0.6
        if Float(colourful.filter { $0 }.count) > 0.10 * Float(sample.count) {
            var hist = [Float](repeating: 0, count: 24)
            var sats: [Float] = []
            for (k, c) in sampleHls.enumerated() where colourful[k] {
                hist[min(23, Int(c.h * 24))] += c.s
                sats.append(c.s)
            }
            let bin = hist.indices.max { hist[$0] < hist[$1] }!
            hue = (Float(bin) + 0.5) / 24
            sat = min(1, median(sats) * 1.05)
        }
        if tile == nil {
            if let hue {
                // A deep tile of the main colour; nearly black when that colour is itself darkish (red text).
                let mainLum = median(sample.indices.filter { colourful[$0] }.map { lum(p, sample[$0]) })
                tile = rgb(hue, mainLum > 0.3 ? 0.16 : 0.085, sat)
            } else {
                tile = slate
            }
        }

        // 4. Letters cut out of a solid block show the tile through them, so the tile mustn't be
        //    the block's colour (white "TV" cut out of a red box on a red tile would vanish).
        if transparent {
            let solid = p.a.map { $0 > 128 }
            let solidCount = solid.filter { $0 }.count
            var cut = [Bool](repeating: false, count: p.count)
            let (labels, n) = label(solid, p.width, p.height)
            for (id, box) in boxes(labels, n, p.width) {
                let (size, filledHoles) = componentHoles(labels, id, box, p.width)
                if Float(size) > 0.05 * Float(solidCount), Float(size) / Float(size + filledHoles.count) > 0.72 {
                    for i in filledHoles { cut[i] = true }
                }
            }
            if Float(cut.filter { $0 }.count) > 0.01 * Float(solidCount) {
                let ring = zip(dilate(cut, p.width, p.height, 2), solid).map { $0 && $1 }
                let idx = ring.indices.filter { ring[$0] }
                if !idx.isEmpty {
                    let around = LogoRGB(r: median(idx.map { p.r[$0] }), g: median(idx.map { p.g[$0] }), b: median(idx.map { p.b[$0] }))
                    let aroundLum = lum(around.r / 255, around.g / 255, around.b / 255)
                    let spread = (max(around.r, around.g, around.b) - min(around.r, around.g, around.b)) / 255
                    let darkNeutral = aroundLum < 0.04 && spread < 0.25
                    if dist(around, tile!) < 110 && !darkNeutral {
                        tile = dist(around, slate) > 110 ? slate : lightGrey
                    }
                }
            }
        }

        // 5. Black/dark-grey shapes sitting straight on a dark tile become white (not dark text
        //    inside a light shape, and not a dark plate with light lettering in it).
        var tileLum = lum(tile!.r / 255, tile!.g / 255, tile!.b / 255)
        let beforeWhite = p
        if tileLum < 0.2 {
            let pw = p.width, ph = p.height
            var dark = [Bool](repeating: false, count: p.count)
            for i in 0..<p.count where p.a[i] > 30 {
                let mx = max(p.r[i], p.g[i], p.b[i]) / 255, mn = min(p.r[i], p.g[i], p.b[i]) / 255
                let s = mx > 0 ? (mx - mn) / mx : 0
                dark[i] = lum(p, i) < max(0.04, tileLum * 1.6) && s < 0.55
            }
            if dark.contains(true) {
                let (labels, n) = label(dark, pw, ph)
                let nearClear = dilate(p.a.map { $0 < 40 }, pw, ph, 2)
                let inner = erode(dark, pw, ph)
                var perimeter = [Int](repeating: 0, count: n + 1)
                var onTile = [Int](repeating: 0, count: n + 1)
                for y in 0..<ph {
                    for x in 0..<pw {
                        let i = y * pw + x
                        guard dark[i], !inner[i] else { continue }
                        let id = Int(labels[i])
                        perimeter[id] += 1
                        if nearClear[i] { onTile[id] += 1 }
                        if x == 0 || y == 0 || x == pw - 1 || y == ph - 1 { onTile[id] += 1 }
                    }
                }
                var whiten = Set<Int32>()
                for (id, box) in boxes(labels, n, pw) where perimeter[Int(id)] > 0 && Float(onTile[Int(id)]) >= 0.35 * Float(perimeter[Int(id)]) {
                    let (size, holes) = componentHoles(labels, id, box, pw)
                    let lettering = holes.filter { p.a[$0] > 128 }.count
                    if Float(lettering) < 0.08 * Float(size) { whiten.insert(id) }
                }
                if !whiten.isEmpty {
                    for i in 0..<p.count where whiten.contains(labels[i]) {
                        p.r[i] = 242; p.g[i] = 242; p.b[i] = 242
                    }
                }
            }
        }

        // 6. Last check: is the logo readable on its tile?
        let vis2 = (0..<p.count).filter { p.a[$0] > 160 }
        if !vis2.isEmpty && !boxKept {
            var logoLum = median(vis2.map { lum(p, $0) })
            let s2 = stride(vis2, max: 3000)
            let h2 = s2.map { hls(p.r[$0] / 255, p.g[$0] / 255, p.b[$0] / 255) }
            let lightShare = Float(h2.filter { $0.l > 0.80 }.count) / Float(h2.count)
            var other: Float = 0
            if let hue {
                var otherCount = 0
                var dom: [Int] = []
                for (k, c) in h2.enumerated() {
                    let isColour = c.s > 0.30 && c.l > 0.12 && c.l < 0.88
                    let dh = abs((c.h - hue + 1.5).truncatingRemainder(dividingBy: 1) - 0.5)
                    if isColour && dh > 0.07 { otherCount += 1 }
                    if isColour && dh <= 0.07 { dom.append(s2[k]) }
                }
                other = Float(otherCount) / Float(h2.count)
                if dom.count > 20 && Float(dom.count) > 0.25 * Float(h2.count) {
                    // Judge it on the logo's main colour when that is a good part of it.
                    let mainLum = median(dom.map { lum(p, $0) })
                    if contrast(mainLum, tileLum) < contrast(logoLum, tileLum) { logoLum = mainLum }
                }
            }
            let oneColour = lightShare < 0.04 && other < 0.06
            if contrast(logoLum, tileLum) < (oneColour ? 4.0 : 3.2) {
                if oneColour {
                    // White logo on a vivid tile of its own colour.
                    tile = hue.map { rgb($0, 0.42, min(0.85, max(0.5, sat))) } ?? LogoRGB(r: 58, g: 64, b: 82)
                    for i in 0..<p.count { p.r[i] = 245; p.g[i] = 245; p.b[i] = 245 }
                } else {
                    // Several colours, made for a light background: a soft pastel tile of its colour.
                    tile = hue.map { rgb($0, 0.86, 0.35) } ?? lightGrey
                    p = beforeWhite
                }
                tileLum = lum(tile!.r / 255, tile!.g / 255, tile!.b / 255)
            }
        }
        let glow = tileLum < 0.2 ? tile! : (hue.map { rgb($0, 0.30, max(0.4, sat)) } ?? slate)
        return CleanedLogo(pixels: p, tile: tile!, glow: glow, mode: .logo)
    }

    // MARK: - Taking the box off

    /// Makes the box colour transparent. Box-coloured areas inside the logo go only when they are
    /// the inside of a letter or ring (BBC Two's O); inside a solid block (the white letters in
    /// Sky's red box, Film4's white 4 in its black box) they are part of the logo and stay.
    static func removeBox(_ p: inout LogoPixels, _ bg: LogoRGB) {
        let w = p.width, h = p.height, n = p.count
        var k = [Float](repeating: 1, count: n)  // 0 = box colour, 1 = logo
        var removed = [Bool](repeating: false, count: n)
        for i in 0..<n {
            k[i] = min(1, max(0, (dist(p, i, bg) - 22) / 58))
            removed[i] = k[i] < 0.5
        }
        let (rl, rn) = label(removed, w, h)
        var touchesEdge = Set<Int32>()
        for i in borderIndices(w, h, thickness: 1) where rl[i] > 0 { touchesEdge.insert(rl[i]) }
        let outside = rl.map { $0 > 0 && touchesEdge.contains($0) }
        _ = rn
        let solid = removed.map { !$0 }
        let (sl, _) = label(solid, w, h)
        var holeMask = [Bool](repeating: false, count: n)
        for i in 0..<n where removed[i] && !outside[i] { holeMask[i] = true }
        let (hl, hn) = label(holeMask, w, h)
        var keep = [Bool](repeating: false, count: n)
        var solidity: [Int32: Float] = [:]
        let solidBoxes = Dictionary(uniqueKeysWithValues: boxes(sl, Int(sl.max() ?? 0), w))
        for (id, box) in boxes(hl, hn, w) {
            // The shape around the hole (looking a few pixels out).
            let bx0 = max(0, box.x0 - 4), by0 = max(0, box.y0 - 4)
            let bx1 = min(w - 1, box.x1 + 4), by1 = min(h - 1, box.y1 + 4)
            let lw = bx1 - bx0 + 1, lh = by1 - by0 + 1
            var local = [Bool](repeating: false, count: lw * lh)
            for y in by0...by1 { for x in bx0...bx1 where hl[y * w + x] == id { local[(y - by0) * lw + (x - bx0)] = true } }
            let ring = dilate(local, lw, lh, 3)
            var votes: [Int32: Int] = [:]
            for y in 0..<lh {
                for x in 0..<lw where ring[y * lw + x] {
                    let gi = (y + by0) * w + (x + bx0)
                    if solid[gi] { votes[sl[gi], default: 0] += 1 }
                }
            }
            guard let around = votes.max(by: { $0.value < $1.value })?.key, let sbox = solidBoxes[around] else { continue }
            if solidity[around] == nil {
                let (size, holes) = componentHoles(sl, around, sbox, w)
                solidity[around] = Float(size) / Float(max(1, size + holes.count))
            }
            if solidity[around]! > 0.72 {
                for y in by0...by1 { for x in bx0...bx1 where hl[y * w + x] == id { keep[y * w + x] = true } }
            }
        }
        let nearKeep = zip(dilate(keep, w, h, 2), outside).map { $0 && !$1 }
        var gone = [Bool](repeating: false, count: n)
        for i in 0..<n { gone[i] = outside[i] || (removed[i] && !keep[i]) }
        let soft = zip(dilate(gone, w, h, 2), nearKeep).map { $0 && !$1 }
        for i in 0..<n {
            let kk: Float = gone[i] || soft[i] ? k[i] : 1
            guard kk < 1 else { continue }
            // Un-mix the box colour out of anti-aliased edge pixels, so edges stay clean.
            let safe = max(kk, 0.001)
            p.r[i] = min(255, max(0, (p.r[i] - bg.r * (1 - kk)) / safe))
            p.g[i] = min(255, max(0, (p.g[i] - bg.g * (1 - kk)) / safe))
            p.b[i] = min(255, max(0, (p.b[i] - bg.b * (1 - kk)) / safe))
            p.a[i] *= kk
        }
    }

    // MARK: - Shapes (4-connected, like scipy.ndimage's defaults the prototype used)

    struct Box { var x0: Int, y0: Int, x1: Int, y1: Int }

    /// Labels connected areas of `mask` 1…n (0 = not in the mask).
    static func label(_ mask: [Bool], _ w: Int, _ h: Int) -> ([Int32], Int) {
        var labels = [Int32](repeating: 0, count: mask.count)
        var next: Int32 = 0
        var queue: [Int] = []
        queue.reserveCapacity(1024)
        for start in 0..<mask.count where mask[start] && labels[start] == 0 {
            next += 1
            labels[start] = next
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % w, y = i / w
                if x > 0, mask[i - 1], labels[i - 1] == 0 { labels[i - 1] = next; queue.append(i - 1) }
                if x < w - 1, mask[i + 1], labels[i + 1] == 0 { labels[i + 1] = next; queue.append(i + 1) }
                if y > 0, mask[i - w], labels[i - w] == 0 { labels[i - w] = next; queue.append(i - w) }
                if y < h - 1, mask[i + w], labels[i + w] == 0 { labels[i + w] = next; queue.append(i + w) }
            }
        }
        return (labels, Int(next))
    }

    static func boxes(_ labels: [Int32], _ n: Int, _ w: Int) -> [(Int32, Box)] {
        guard n > 0 else { return [] }
        var b = [Box](repeating: Box(x0: Int.max, y0: Int.max, x1: -1, y1: -1), count: n + 1)
        for (i, id) in labels.enumerated() where id > 0 {
            let x = i % w, y = i / w
            let j = Int(id)
            b[j].x0 = min(b[j].x0, x); b[j].y0 = min(b[j].y0, y)
            b[j].x1 = max(b[j].x1, x); b[j].y1 = max(b[j].y1, y)
        }
        return (1...n).compactMap { b[$0].x1 >= 0 ? (Int32($0), b[$0]) : nil }
    }

    /// A shape's size and the pixels (image indices) of its holes: the areas it fully encloses.
    static func componentHoles(_ labels: [Int32], _ id: Int32, _ box: Box, _ w: Int) -> (Int, [Int]) {
        let bw = box.x1 - box.x0 + 1, bh = box.y1 - box.y0 + 1
        var inShape = [Bool](repeating: false, count: bw * bh)
        var size = 0
        for y in 0..<bh {
            for x in 0..<bw where labels[(y + box.y0) * w + x + box.x0] == id { inShape[y * bw + x] = true; size += 1 }
        }
        // Everything else in the box that can't reach the box's edge is a hole.
        let (outLabels, _) = label(inShape.map { !$0 }, bw, bh)
        var reachesEdge = Set<Int32>()
        for i in borderIndices(bw, bh, thickness: 1) where outLabels[i] > 0 { reachesEdge.insert(outLabels[i]) }
        var holes: [Int] = []
        for i in 0..<(bw * bh) where outLabels[i] > 0 && !reachesEdge.contains(outLabels[i]) {
            holes.append((i / bw + box.y0) * w + (i % bw) + box.x0)
        }
        return (size, holes)
    }

    static func dilate(_ mask: [Bool], _ w: Int, _ h: Int, _ times: Int) -> [Bool] {
        var m = mask
        for _ in 0..<times {
            var out = m
            for i in 0..<m.count where !m[i] {
                let x = i % w, y = i / w
                if (x > 0 && m[i - 1]) || (x < w - 1 && m[i + 1]) || (y > 0 && m[i - w]) || (y < h - 1 && m[i + w]) { out[i] = true }
            }
            m = out
        }
        return m
    }

    static func erode(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var out = mask
        for i in 0..<mask.count where mask[i] {
            let x = i % w, y = i / w
            // Outside the picture counts as empty, as in scipy's binary_erosion.
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 || !mask[i - 1] || !mask[i + 1] || !mask[i - w] || !mask[i + w] {
                out[i] = false
            }
        }
        return out
    }

    static func borderIndices(_ w: Int, _ h: Int, thickness t: Int) -> [Int] {
        var out: [Int] = []
        for y in 0..<h {
            for x in 0..<w where x < t || y < t || x >= w - t || y >= h - t { out.append(y * w + x) }
        }
        return out
    }

    // MARK: - Colour

    static func dist(_ p: LogoPixels, _ i: Int, _ c: LogoRGB) -> Float {
        let dr = p.r[i] - c.r, dg = p.g[i] - c.g, db = p.b[i] - c.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    static func dist(_ a: LogoRGB, _ c: LogoRGB) -> Float {
        let dr = a.r - c.r, dg = a.g - c.g, db = a.b - c.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Relative luminance (WCAG), from 0…1 components.
    static func lum(_ r: Float, _ g: Float, _ b: Float) -> Float {
        func lin(_ c: Float) -> Float { c <= 0.03928 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func lum(_ p: LogoPixels, _ i: Int) -> Float { lum(p.r[i] / 255, p.g[i] / 255, p.b[i] / 255) }

    static func contrast(_ l1: Float, _ l2: Float) -> Float { (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05) }

    /// Hue, lightness, saturation (0…1), as Python's colorsys.
    static func hls(_ r: Float, _ g: Float, _ b: Float) -> (h: Float, l: Float, s: Float) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return (0, l, 0) }
        let d = mx - mn
        let s = l <= 0.5 ? d / (mx + mn) : d / (2 - mx - mn)
        var h: Float
        if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return (h, l, s)
    }

    static func rgb(_ h: Float, _ l: Float, _ s: Float) -> LogoRGB {
        if s == 0 { return LogoRGB(r: l * 255, g: l * 255, b: l * 255) }
        let m2 = l <= 0.5 ? l * (1 + s) : l + s - l * s
        let m1 = 2 * l - m2
        func v(_ hue: Float) -> Float {
            var hh = hue.truncatingRemainder(dividingBy: 1)
            if hh < 0 { hh += 1 }
            if hh < 1 / 6 { return m1 + (m2 - m1) * hh * 6 }
            if hh < 0.5 { return m2 }
            if hh < 2 / 3 { return m1 + (m2 - m1) * (2 / 3 - hh) * 6 }
            return m1
        }
        return LogoRGB(r: v(h + 1 / 3) * 255, g: v(h) * 255, b: v(h - 1 / 3) * 255)
    }

    /// A deep version of a colour, for the background glow.
    /// Artwork that can't be lifted off its background is shown whole, as a rounded card centred
    /// on a deep tile of its main colour (stretching it across the tile looked wrong: ITV1's
    /// yellow/white blocks, Sky Sports Main Event's stacked bars).
    static func picture(_ p: LogoPixels) -> CleanedLogo {
        let idx = stride((0..<p.count).filter { p.a[$0] > 200 }, max: 3000)
        var hist = [Float](repeating: 0, count: 24)
        var sats: [Float] = []
        for i in idx {
            let c = hls(p.r[i] / 255, p.g[i] / 255, p.b[i] / 255)
            guard c.s > 0.30, c.l > 0.12, c.l < 0.88 else { continue }
            hist[min(23, Int(c.h * 24))] += c.s
            sats.append(c.s)
        }
        var tile = slate
        if Float(sats.count) > 0.10 * Float(max(1, idx.count)) {
            let bin = hist.indices.max { hist[$0] < hist[$1] }!
            tile = rgb((Float(bin) + 0.5) / 24, 0.14, min(0.75, median(sats)))
        }
        return CleanedLogo(pixels: p, tile: tile, glow: tile, mode: .picture)
    }

    static func deep(_ c: LogoRGB) -> LogoRGB {
        let x = hls(c.r / 255, c.g / 255, c.b / 255)
        return rgb(x.h, min(x.l, 0.3), x.s)
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func stride(_ idx: [Int], max: Int) -> [Int] {
        let step = Swift.max(1, idx.count / max)
        return Swift.stride(from: 0, to: idx.count, by: step).map { idx[$0] }
    }
}
