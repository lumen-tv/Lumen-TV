package com.hayat.lumen.util

/** A channel name split for display: "UK: BBC ONE LONDON 4K ●" → "BBC One London" + ["4K"]. */
data class DisplayName(val title: String, val tags: List<String>)

/**
 * Tidies the raw names IPTV playlists use. The stored name is never changed (stable keys and
 * search use it); this is only how it's shown.
 */
object ChannelNames {
    // Country/region prefixes: "UK: ", "UK | ", "|UK| ", "[US] ", "US - ", "UK⋆ ".
    private val prefix = Regex("""^\s*(\[[^]]*]|\|[^|]*\||[A-Za-z]{2,3}\s*[:|⋆★•-]+)\s*""")

    // Quality/format tags, kept as small chips. Order matters: the first match per kind wins.
    private val qualityTags = listOf(
        "8K" to Regex("""(?i)\b8K\b"""),
        "4K" to Regex("""(?i)\b(4K|UHD|2160P?)\b|ᵁᴴᴰ|⁴ᴷ"""),
        "HD" to Regex("""(?i)\b(FHD|HD|1080P?|720P?)\b|ᴴᴰ|ᶠᴴᴰ"""),
    )
    private val noise = Regex("""(?i)\b(SD|HEVC|H\.?26[45]|50FPS|60FPS|RAW|VIP|BACKUP|MULTI|HDR)\b""")
    private val brackets = Regex("""[(\[{]\s*[)\]}]""")
    // Written as "not one of these, then not a letter/digit/space" because Kotlin/Native (iOS)
    // ignores the plain characters in a negated class that also has \p{…} (`[^\p{L}-]` drops '-').
    private val symbols = Regex("""(?![-&+'’!.:/()])[^\p{L}\p{N}\s]""")
    private val spaces = Regex("""\s+""")
    private val trailingJunk = Regex("""[\s:|/.-]+$""")

    // All-caps words that should stay all-caps when the rest of the name is title-cased.
    private val acronyms = setOf(
        "ABC", "AMC", "AXN", "BBC", "BET", "BT", "CBS", "CNBC", "CNN", "DAZN", "E4", "ESPN", "EPL", "EWTN",
        "FX", "GB", "HBO", "HGTV", "ITV", "ITV1", "ITV2", "ITV3", "ITV4", "ITVBE", "MTV", "NBA", "NBC", "NFL",
        "NHL", "PBS", "QVC", "RTE", "S4C", "STV", "TBS", "TCM", "TF1", "TLC", "TNT", "TV", "UFC", "UK", "US",
        "USA", "WWE", "MLB", "MUTV", "LFCTV", "BBC1", "BBC2", "TG4", "UTV", "OSN",
    )

    fun display(raw: String): DisplayName {
        var name = raw.replace(prefix, "")
        val tags = mutableListOf<String>()
        for ((tag, pattern) in qualityTags) {
            if (pattern.containsMatchIn(name)) {
                if (tags.isEmpty()) tags += tag // only the best quality is worth showing
                name = name.replace(pattern, " ")
            }
        }
        name = name.replace(noise, " ")
            .replace(symbols, " ")
            .replace(brackets, " ")
            .replace(spaces, " ")
            .replace(trailingJunk, "")
            .trim()
        if (name.isEmpty()) name = raw.trim()
        if (name.none { it.isLowerCase() }) name = titleCase(name)
        return DisplayName(name, tags)
    }

    fun title(raw: String): String = display(raw).title

    /** "BBC ONE LONDON" → "BBC One London". Only used on all-caps names, so "iPlayer" etc. are left alone. */
    private fun titleCase(name: String): String = name.split(' ').joinToString(" ") { word ->
        val letters = word.filter { it.isLetter() }
        when {
            word.uppercase().trimEnd('+') in acronyms -> word // "OSN+" too
            letters.length <= 1 -> word
            // No vowels, or mixed with digits: an abbreviation like "TNT" or "5USA".
            letters.none { it.uppercaseChar() in "AEIOUY" } -> word
            word.any { it.isDigit() } -> word
            else -> word.lowercase().replaceFirstChar { it.uppercaseChar() }
                .replace(Regex("""(?<=[-'’/(])\p{Ll}""")) { it.value.uppercase() }
        }
    }
}
