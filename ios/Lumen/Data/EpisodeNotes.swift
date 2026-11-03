import Foundation

/// An episode's description and still from TVmaze, for the episodes the provider sends without
/// them (Hayat 2026-11-03: many of their provider's episodes had no description).
struct EpisodeNote: Codable, Hashable {
    var summary: String?
    var image: String?
}

/// TVmaze (api.tvmaze.com): a free TV database with no key or sign-up. Its data is CC BY-SA, so
/// the series page says where the text came from. The show is found by its IMDb id when OMDb
/// gave one, else by name (and year); then all its episodes come in one request.
/// Kept in memory, and on the phone for a week (Caches/Lumen/tvmaze-<key>.json).
@MainActor
final class EpisodeNotes {
    static let shared = EpisodeNotes()

    /// Season|episode → note, per show (looked-up shows only; misses are kept for the session).
    private var cache: [String: [String: EpisodeNote]] = [:]

    /// Notes for a show's episodes, keyed `"<season>|<episode>"`. Empty when TVmaze doesn't know
    /// the show or can't be reached.
    func notes(title: String, year: Int?, imdbId: String?) async -> [String: EpisodeNote] {
        let key = imdbId ?? "\(title.lowercased())|\(year.map(String.init) ?? "")"
        if let hit = cache[key] { return hit }
        let path = Self.cachePath(key)
        if let saved = Self.load(path), !Self.isOld(path) {
            cache[key] = saved
            return saved
        }
        guard let showId = await showId(title: title, year: year, imdbId: imdbId),
              let url = URL(string: "https://api.tvmaze.com/shows/\(showId)/episodes"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let episodes = try? JSONDecoder().decode([Episode].self, from: data)
        else {
            // An old copy beats nothing; a plain miss isn't asked again this session.
            let fallback = Self.load(path) ?? [:]
            cache[key] = fallback
            return fallback
        }
        var notes: [String: EpisodeNote] = [:]
        for episode in episodes {
            guard let season = episode.season, let number = episode.number else { continue }
            let note = EpisodeNote(summary: episode.summary.flatMap(Self.plainText), image: episode.image?.medium)
            if note.summary != nil || note.image != nil { notes["\(season)|\(number)"] = note }
        }
        if cache.count > 100 { cache.removeAll() }
        cache[key] = notes
        if let encoded = try? JSONEncoder().encode(notes) { try? encoded.write(to: URL(fileURLWithPath: path)) }
        return notes
    }

    private func showId(title: String, year: Int?, imdbId: String?) async -> Int? {
        if let imdbId, let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdbId)"),
           let (data, response) = try? await URLSession.shared.data(from: url), // follows TVmaze's redirect
           (response as? HTTPURLResponse)?.statusCode == 200,
           let show = try? JSONDecoder().decode(Show.self, from: data) {
            return show.id
        }
        var components = URLComponents(string: "https://api.tvmaze.com/search/shows")
        components?.queryItems = [URLQueryItem(name: "q", value: title)]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONDecoder().decode([SearchResult].self, from: data)
        else { return nil }
        // Same name (ignoring case and punctuation), and the same first year when we know it:
        // a remake shares the name.
        let wanted = Self.simple(title)
        let named = results.map(\.show).filter { Self.simple($0.name ?? "") == wanted }
        if let year {
            return named.first { $0.premiered?.prefix(4) == "\(year)" }?.id
                ?? (named.count == 1 ? named.first?.id : nil)
        }
        return named.first?.id
    }

    // MARK: TVmaze's JSON (only the fields used)

    private struct Show: Decodable { let id: Int; let name: String?; let premiered: String? }
    private struct SearchResult: Decodable { let show: Show }
    private struct Episode: Decodable {
        let season: Int?
        let number: Int?
        let summary: String?
        let image: Image?
        struct Image: Decodable { let medium: String? }
    }

    // MARK: Helpers

    private static func simple(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// TVmaze's summaries are small HTML ("<p>Logan <b>considers</b>…</p>").
    private static func plainText(_ html: String) -> String? {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cachePath(_ key: String) -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = key.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return dir.appendingPathComponent("tvmaze-\(safe.prefix(80)).json").path
    }

    private static func load(_ path: String) -> [String: EpisodeNote]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([String: EpisodeNote].self, from: data)
    }

    private static func isOld(_ path: String) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return true }
        return Date.now.timeIntervalSince(modified) > 7 * 24 * 3600
    }
}
