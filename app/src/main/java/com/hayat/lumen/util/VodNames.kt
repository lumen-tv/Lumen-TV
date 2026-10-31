package com.hayat.lumen.util

/**
 * Cleans film and series names for display. Providers prefix titles with a source or
 * language tag and suffix a year and country:
 * `4K-NF - Lupin (2021) (FR)` → title "Lupin", year 2021, tags ["4K"].
 * Display only: stored names never change (search still matches the raw name).
 */
object VodNames {
    data class Name(val title: String, val year: Int?, val tags: List<String>)

    /** `EN - `, `4K-AMZ - `, `D+ - `, `NF-DO - `: short upper-case codes before a spaced dash. */
    private val prefix = Regex("^((?:\\d[KM]-)?[A-Z0-9+]{1,4}(?:-[A-Z0-9+]{1,4})?)\\s*[-|:]\\s+")
    private val yearAtEnd = Regex("\\s*\\((\\d{4})\\)\\s*$")
    private val countryAtEnd = Regex("\\s*\\(([A-Z]{2})\\)\\s*$")
    private val spaces = Regex("\\s{2,}")

    fun display(raw: String): Name {
        var s = raw.trim()
        val tags = ArrayList<String>()
        prefix.find(s)?.let { m ->
            val rest = s.substring(m.range.last + 1)
            if (rest.isNotBlank()) {
                val code = m.groupValues[1]
                if (code.startsWith("4K")) tags += "4K"
                if (code.endsWith("-CAM")) tags += "CAM"
                s = rest
            }
        }
        var year: Int? = null
        // Year and country come in either order: "(2021) (FR)" or "(FR) (2021)".
        repeat(2) {
            countryAtEnd.find(s)?.let { s = s.substring(0, it.range.first) }
            yearAtEnd.find(s)?.let { m ->
                if (year == null) year = m.groupValues[1].toInt()
                s = s.substring(0, m.range.first)
            }
        }
        s = s.replace(spaces, " ").trim().ifEmpty { raw.trim() }
        return Name(s, year, tags)
    }

    /** `S01E03`, `S1 E3`, `1x03` and everything before it (provider tag, show name). */
    private val episodeCode = Regex("(?i)^.*?(?:\\bS\\d{1,2}\\s?E\\d{1,3}|\\b\\d{1,2}x\\d{2,3})\\b")
    /** A leading `Episode 3`, `Ep. 3` or `E03` with nothing else in it. */
    private val episodeWord = Regex("(?i)^(?:episode|ep\\.?|e)\\s?\\d{1,3}\\b")
    /** Release noise at the end: `[1080p]`, `(720p)`, `4K`, `HDR`, `x265`, `WEB-DL`. */
    private val qualityAtEnd = Regex("(?i)[\\s.]*[\\[(]?\\b(?:2160p|1080p|720p|480p|4k|uhd|fhd|hdr10?|hevc|[hx]\\.?26[45]|web-?(?:dl|rip)|bluray)\\b[\\])]?\\s*$")
    /** Dashes, colons and dots left at either end (a trailing "..." is part of the name). */
    private val separators = Regex("^[\\s\\-:–—|.·]+|[\\s\\-:–—|·]+$")

    /**
     * Cleans an episode's name for display. Providers send things like
     * `D+ - Modern Family S01E03 - Come Fly with Me` or `NF - Lupin - S01E01`;
     * the series page and the player only need `Come Fly with Me`.
     * [series] is the show's (already cleaned) name, dropped when the episode repeats it.
     * Null when nothing is left but codes, so callers show "Episode 3".
     */
    fun episode(raw: String?, series: String? = null): String? {
        var s = raw?.trim().orEmpty()
        if (s.isEmpty()) return null
        val code = episodeCode.find(s)
        if (code != null) {
            s = s.substring(code.range.last + 1)
        } else {
            s = display(s).title
            series?.trim()?.takeIf { it.isNotEmpty() }?.let { name ->
                // Only "Lost - Pilot", never "Lost Souls".
                val rest = if (s.startsWith(name, ignoreCase = true)) s.substring(name.length) else null
                if (rest != null && (rest.isBlank() || rest.trimStart().first() in "-:–—|·")) s = rest
            }
        }
        repeat(2) {
            s = s.replace(separators, "")
            s = s.replace(qualityAtEnd, "")
            s = s.replace(episodeWord, "")
        }
        s = s.replace(separators, "").replace(spaces, " ").trim()
        // Just the show's name again ("Modern Family S01E03" or "Modern Family"): nothing to add.
        if (series != null && s.equals(series.trim(), ignoreCase = true)) return null
        return s.ifEmpty { null }
    }
}
