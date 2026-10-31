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
}
