import Foundation

/// Scores for one title from OMDb. Each is nil when OMDb doesn't have it.
struct OmdbRatings {
    /// "7.5" (out of 10).
    var imdb: String?
    /// "94%".
    var rottenTomatoes: String?
    /// "PG-13", "12A".
    var age: String?
    /// How many people rated it on IMDb.
    var imdbVotes: Int?
    /// "tt0903747"; also used to look up intro times.
    var imdbId: String? = nil

    var isEmpty: Bool { imdb == nil && rottenTomatoes == nil && age == nil }
}

/// OMDb (omdbapi.com): IMDb, Rotten Tomatoes and age ratings with the user's own free key, as on
/// the TV (`OmdbClient`). The key lives in the Keychain and is never logged. Shown as plain text:
/// the App Store build carries no other company's logos.
@MainActor
final class Omdb {
    static let shared = Omdb()
    enum KeyCheck { case works, rejected, unreachable }

    private static let account = "omdb-key"
    private static let base = "https://www.omdbapi.com/"
    /// Titles looked up this session (hits and misses). The free key allows 1,000 a day.
    private var cache: [String: OmdbRatings] = [:]

    var key: String? {
        Keychain.load(Self.account).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    func setKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty { Keychain.delete(Self.account) } else { Keychain.save(Data(trimmed.utf8), for: Self.account) }
        cache.removeAll()
    }

    /// Looks up one well-known film to see whether OMDb accepts [key].
    func check(_ key: String) async -> KeyCheck {
        guard let url = Self.url(["apikey": key.trimmingCharacters(in: .whitespaces), "i": "tt0111161"]) else { return .rejected }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let body = String(decoding: data, as: UTF8.self)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || body.contains("Invalid API key") { return .rejected }
            return code == 200 && body.contains("\"Response\":\"True\"") ? .works : .unreachable
        } catch {
            return .unreachable
        }
    }

    /// Nil without a key, when OMDb can't be reached, or doesn't know the title.
    func ratings(title: String, year: Int?, series: Bool) async -> OmdbRatings? {
        guard let key else { return nil }
        let id = "\(series ? "s" : "m")|\(title.lowercased())|\(year.map(String.init) ?? "")"
        if let hit = cache[id] { return hit.isEmpty ? nil : hit }
        var query = ["apikey": key, "t": title, "type": series ? "series" : "movie"]
        if let year { query["y"] = String(year) }
        guard let url = Self.url(query),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let found = Self.parse(data)
        else { return nil } // not cached: a network blip shouldn't hide scores all session
        if cache.count > 300 { cache.removeAll() }
        cache[id] = found
        return found.isEmpty ? nil : found
    }

    private static func url(_ query: [String: String]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }

    private static func parse(_ data: Data) -> OmdbRatings? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard json["Response"] as? String == "True" else { return OmdbRatings() }
        func clean(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text != "N/A" else { return nil }
            return text
        }
        let sources = json["Ratings"] as? [[String: Any]] ?? []
        let tomatoes = sources.first { $0["Source"] as? String == "Rotten Tomatoes" }.flatMap { clean($0["Value"]) }
        let age = clean(json["Rated"]).flatMap { $0 == "Not Rated" || $0 == "Unrated" ? nil : $0 }
        let votes = clean(json["imdbVotes"]).flatMap { Int($0.filter(\.isNumber)) } // "32,756"
        return OmdbRatings(imdb: clean(json["imdbRating"]), rottenTomatoes: tomatoes, age: age, imdbVotes: votes,
                           imdbId: clean(json["imdbID"]).flatMap { $0.hasPrefix("tt") ? $0 : nil })
    }
}

extension OmdbRatings {
    /// The row under a film or series page's buttons: Rotten Tomatoes, IMDb (with votes), age.
    /// The provider's own score only when OMDb has neither.
    static func items(_ omdb: OmdbRatings?, provider: Double?, age: String?) -> [(value: String, label: String)] {
        var items: [(value: String, label: String)] = []
        if let tomatoes = omdb?.rottenTomatoes { items.append((tomatoes, "Rotten Tomatoes")) }
        if let imdb = omdb?.imdb {
            let votes = omdb?.imdbVotes.map { " · \($0.formatted(.number.notation(.compactName))) votes" } ?? ""
            items.append((imdb, "IMDb\(votes)"))
        }
        if items.isEmpty, let provider, provider > 0 { items.append((String(format: "%.1f", provider), "Rating")) }
        if let age = omdb?.age ?? age { items.append((age, "Age rating")) }
        return items
    }
}
