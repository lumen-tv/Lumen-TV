import Foundation

/// A part of an episode that can be skipped, in seconds from the start of the file.
struct SkipSegment: Equatable {
    enum Kind: CaseIterable { case intro, recap, credits }
    let kind: Kind
    let start: Double
    let end: Double?
}

/// What the player offers right now. `target` is where Skip jumps; nil means "Next episode".
struct SkipOffer: Equatable {
    let kind: SkipSegment.Kind
    let segmentStart: Double
    let target: Double?

    var label: String {
        switch kind {
        case .intro: "Skip intro"
        case .recap: "Skip recap"
        case .credits: "Next episode"
        }
    }
}

/// Which show and episode to look up (same as `EpisodeRef` on the TV).
struct SkipRef {
    let seriesTitle: String
    let year: Int?
    let tmdbId: String?
    let season: Int
    let episode: Int
    let durationSecs: Int?
}

/// The same rules as `SkipPick` on the TV: intro/recap while they play (wherever they fall, so
/// after a cold open too), "Next episode" from the credits in the second half when there is one.
enum SkipPick {
    /// For credits, a source that gives their end wins: only then is their length known.
    static func merge(_ sources: [[SkipSegment]]) -> [SkipSegment] {
        SkipSegment.Kind.allCases.compactMap { kind in
            let all = sources.compactMap { $0.first { $0.kind == kind } }
            return kind == .credits ? (all.first { $0.end != nil } ?? all.first) : all.first
        }
    }

    /// "Next episode" never shows earlier than this before the end.
    static let creditsLatest: Double = 120

    /// As `SkipPick.creditsStart` on the TV: the databases' copy and the provider's file differ in
    /// length, so the credits' length is counted back from this file's end, and never more than
    /// two minutes before it.
    static func creditsStart(_ credits: SkipSegment, duration: Double) -> Double {
        var start = credits.start
        if let end = credits.end, end - credits.start >= 5, end - credits.start <= creditsLatest {
            start = duration - (end - credits.start)
        }
        return max(start, duration - creditsLatest)
    }

    static func at(_ segments: [SkipSegment], position: Double, duration: Double, hasNext: Bool) -> SkipOffer? {
        for s in segments {
            switch s.kind {
            case .intro, .recap:
                guard let end = s.end, duration <= 0 || end < duration else { continue }
                if position >= s.start && position < end - 2 { return SkipOffer(kind: s.kind, segmentStart: s.start, target: end) }
            case .credits:
                guard hasNext, duration > 0, s.start >= duration / 2 else { continue }
                if position >= creditsStart(s, duration: duration) { return SkipOffer(kind: s.kind, segmentStart: s.start, target: nil) }
            }
        }
        return nil
    }
}

/// Intro, recap and end-credit times per episode from free community databases, as on the TV
/// (`SkipTimesClient`): TheIntroDB by TMDB id, IntroDB and SkipDB by IMDb id. No keys; one
/// small request per episode while the video opens. Nothing found means no button.
@MainActor
final class SkipTimes {
    static let shared = SkipTimes()

    private var cache: [String: [SkipSegment]] = [:]
    /// Show name → TMDB id ("" = not found).
    private var tmdbByName: [String: String] = [:]

    func segments(for ref: SkipRef) async -> [SkipSegment] {
        let imdb = await Omdb.shared.ratings(title: ref.seriesTitle, year: ref.year, series: true)?.imdbId
        var tmdb = ref.tmdbId
        if tmdb == nil { tmdb = await tmdbId(name: ref.seriesTitle, year: ref.year) }
        guard tmdb != nil || imdb != nil else { return [] }
        let key = "\(tmdb ?? "")|\(imdb ?? "")|\(ref.season)|\(ref.episode)"
        if let hit = cache[key] { return hit }

        let se = [URLQueryItem(name: "season", value: String(ref.season)), URLQueryItem(name: "episode", value: String(ref.episode))]
        let duration = ref.durationSecs.map { [URLQueryItem(name: "duration", value: String($0))] } ?? []
        async let a = fetch("https://api.theintrodb.org/v2/media", id: tmdb, as: "tmdb_id", se)
        async let b = fetch("https://api.introdb.app/segments", id: imdb, as: "imdb_id", se)
        async let c = fetch("https://api.skipdb.tv/api/segments", id: imdb, as: "imdb_id", se + duration)
        let (ra, rb, rc) = await (a, b, c)
        let found = SkipPick.merge([
            Self.parseTheIntroDb(ra),
            Self.parseIntroDb(rb),
            Self.parseSkipDb(rc),
        ])
        // A network blip isn't cached, so the next try asks again.
        if ra != nil || rb != nil || rc != nil {
            if cache.count > 200 { cache.removeAll() }
            cache[key] = found
        }
        return found
    }

    private func tmdbId(name: String, year: Int?) async -> String? {
        let key = "\(name.lowercased())|\(year.map(String.init) ?? "")"
        if let hit = tmdbByName[key] { return hit.isEmpty ? nil : hit }
        guard let data = await fetch("https://skipdb.tv/api/titles/search", [URLQueryItem(name: "q", value: name)]) else { return nil }
        let id = Self.pickSearchResult(data, name: name, year: year)
        tmdbByName[key] = id ?? ""
        return id
    }

    /// Nil when there's no id to ask with.
    private nonisolated func fetch(_ base: String, id: String?, as name: String, _ query: [URLQueryItem]) async -> Data? {
        guard let id else { return nil }
        return await fetch(base, [URLQueryItem(name: name, value: id)] + query)
    }

    /// The body, empty Data for "not in the database" (404), nil when unreachable.
    private nonisolated func fetch(_ base: String, _ query: [URLQueryItem]) async -> Data? {
        var components = URLComponents(string: base)
        components?.queryItems = query
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let code = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if code == 404 { return Data() }
        return code == 200 ? data : nil
    }

    // MARK: Parsing (the three APIs' answers; see SkipTimesParseTest on the TV)

    private static func object(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func ms(_ value: Any?) -> Double? {
        (value as? NSNumber).map { $0.doubleValue / 1000 }
    }

    /// "No intro" comes as 0–0; under 5 s is noise.
    private static func segment(_ kind: SkipSegment.Kind, _ o: [String: Any]?) -> SkipSegment? {
        guard let o, let start = ms(o["start_ms"]) else { return nil }
        let end = ms(o["end_ms"])
        if let end, end - start < 5 { return nil }
        return SkipSegment(kind: kind, start: start, end: end)
    }

    static func parseTheIntroDb(_ data: Data?) -> [SkipSegment] {
        guard let json = object(data) else { return [] }
        return [("intro", SkipSegment.Kind.intro), ("recap", .recap), ("credits", .credits)].compactMap { field, kind in
            segment(kind, (json[field] as? [[String: Any]])?.first)
        }
    }

    static func parseIntroDb(_ data: Data?) -> [SkipSegment] {
        guard let json = object(data) else { return [] }
        return [("intro", SkipSegment.Kind.intro), ("recap", .recap), ("outro", .credits)].compactMap { field, kind in
            segment(kind, json[field] as? [String: Any])
        }
    }

    static func parseSkipDb(_ data: Data?) -> [SkipSegment] {
        guard let segments = object(data)?["segments"] as? [String: Any] else { return [] }
        return [("intro", SkipSegment.Kind.intro), ("recap", .recap), ("outro", .credits)].compactMap { field, kind in
            guard let o = segments[field] as? [String: Any], o["match"] as? String != "out-of-range" else { return nil }
            return segment(kind, o)
        }
    }

    static func pickSearchResult(_ data: Data, name: String, year: Int?) -> String? {
        guard let results = object(data)?["results"] as? [[String: Any]] else { return nil }
        let wanted = name.lowercased().filter { $0.isLetter || $0.isNumber }
        var best: String?
        for r in results where r["mediaType"] as? String == "series" {
            guard let id = (r["tmdbId"] as? NSNumber)?.stringValue ?? r["tmdbId"] as? String else { continue }
            let sameName = (r["name"] as? String ?? "").lowercased().filter { $0.isLetter || $0.isNumber } == wanted
            let ry = (r["year"] as? NSNumber)?.intValue ?? 0
            if sameName && (year == nil || ry == 0 || abs(ry - (year ?? 0)) <= 1) { return id }
            if best == nil && sameName { best = id }
        }
        return best
    }
}
