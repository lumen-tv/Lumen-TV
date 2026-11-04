import Foundation

/// Finds a channel's logo in github.com/tv-logo/tv-logos by name. The app ships only the list of
/// the collection's file names (`Resources/tv-logos-index.txt`, made by `ios/tools/tv_logos_index.py`);
/// `ChannelLogos` downloads the one logo a channel needs. Plain Swift, so it can be tested anywhere.
struct TvLogoIndex {
    /// key ("bbcone") → the files for it, one per country ("uk" → "countries/united-kingdom/bbc-one-uk.png").
    private var byKey: [String: [(cc: String, path: String)]] = [:]

    init(text: String) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            byKey[String(parts[0]), default: []].append((String(parts[1]), String(parts[2])))
        }
    }

    var isEmpty: Bool { byKey.isEmpty }

    /// The repo path of the logo for this channel, or nil (the app then shows the name tile).
    /// - title: the tidied name ("BBC One London"); rawName/category: the provider's, for a country
    ///   hint ("UK: BBC ONE HD", "UK | Entertainment"); region: the device's region ("GB").
    func match(title: String, rawName: String, category: String?, region: String?) -> String? {
        let hints = [Self.country(rawName), category.flatMap(Self.country), region.map(Self.code)].compactMap { $0 }
        for key in Self.keys(title) {
            guard let files = byKey[key], !files.isEmpty else { continue }
            for cc in hints {
                if let hit = files.first(where: { $0.cc == cc }) { return hit.path }
            }
            if files.count == 1 { return files[0].path }
            // The same name in several countries and no hint matched: guess the most widely used.
            for cc in ["int", "uk", "us"] {
                if let hit = files.first(where: { $0.cc == cc }) { return hit.path }
            }
            return nil
        }
        return nil
    }

    /// Words at the end of a name that tv-logos usually leaves out ("ITV1 London" is "itv-1").
    private static let regional: Set<String> = [
        "london", "england", "east", "west", "north", "south", "northwest", "northeast", "southeast", "southwest",
        "midlands", "yorkshire", "anglia", "granada", "tyne", "tees", "meridian", "central", "border", "wales",
        "scotland", "cymru", "ni", "northern", "ireland", "hd", "uhd", "fhd", "sd", "4k",
        "hevc", "raw", "backup", "plus1",
    ]

    /// The names to look up, most exact first: "BBC One London" → bbconelondon, bbcone.
    static func keys(_ title: String) -> [String] {
        var words = title.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+1", with: " plus1")
            .replacingOccurrences(of: "+", with: " plus ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.first == "the", words.count > 1 { words.removeFirst() }
        var out: [String] = []
        func add(_ w: [String]) {
            let k = w.joined()
            if !k.isEmpty && !out.contains(k) { out.append(k) }
        }
        add(words)
        // "+1" channels are "...-plus" in tv-logos (channel-4-plus-uk).
        if words.last == "plus1" { add(Array(words.dropLast()) + ["plus"]) }
        while let last = words.last, regional.contains(last), words.count > 1 {
            words.removeLast()
            add(words)
        }
        return out
    }

    /// A country code from a provider prefix: "UK: BBC One", "UK | Sports", "[US] CNN", "DE - ARD".
    static func country(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let letters = trimmed.prefix(while: { $0.isLetter })
        guard (2...3).contains(letters.count), letters.uppercased() == String(letters) else { return nil }
        let rest = trimmed.dropFirst(letters.count)
        // Must be followed by a separator, not more of a word ("UKTV" is a channel, not a prefix).
        guard let next = rest.first, !next.isLetter, !next.isNumber else { return nil }
        return code(String(letters))
    }

    /// tv-logos' country codes: "uk" for Britain, "us" for the States, otherwise ISO 2 letters.
    static func code(_ c: String) -> String {
        switch c.lowercased() {
        case "gb", "uk", "gbr": "uk"
        case "usa": "us"
        case "ger", "deu": "de"
        case "fra": "fr"
        case "ita": "it"
        case "esp", "spa": "es"
        case "can": "ca"
        case "aus": "au"
        case "ind": "in"
        default: c.lowercased()
        }
    }
}
