package com.hayat.lumen.data.m3u

/** What kind of stream an M3U entry is. Xtream playlists mix live, films and series. */
enum class EntryKind { LIVE, MOVIE, SERIES }

data class M3uEntry(
    val name: String,
    val url: String,
    val kind: EntryKind,
    val tvgId: String?,
    val tvgName: String?,
    val tvgLogo: String?,
    val groupTitle: String?,
    val tvgChno: Int?,
)

data class M3uHeader(val epgUrl: String?)

/**
 * Streaming M3U/M3U8 parser. [entries] is a lazy sequence that reads one line at a
 * time, so a 200k-entry playlist never sits in memory at once.
 *
 * Never throws on bad data: malformed entries are counted in [skipped] and dropped.
 */
class M3uParser {

    var skipped = 0
        private set
    var header = M3uHeader(epgUrl = null)
        private set

    // `sequence { yield(x) }` is Kotlin's generator, like a Swift AsyncSequence
    // without the async: each entry is produced only when the caller asks for it.
    // [lines] is read lazily too: on Android `reader.lineSequence()`, on iPhone the downloaded text's lines.
    fun entries(lines: Sequence<String>): Sequence<M3uEntry> = sequence {
        var pending: Extinf? = null
        var pendingGroup: String? = null
        var first = true

        for (raw in lines) {
            var line = raw
            if (first) {
                line = line.removePrefix("\uFEFF") // UTF-8 byte-order mark
                first = false
            }
            line = line.trim()
            if (line.isEmpty()) continue

            when {
                line.startsWith("#EXTM3U", ignoreCase = true) -> {
                    val attrs = parseAttributes(line.substring("#EXTM3U".length))
                    header = M3uHeader(epgUrl = attrs["x-tvg-url"] ?: attrs["url-tvg"])
                }
                line.startsWith("#EXTINF", ignoreCase = true) -> {
                    if (pending != null) skipped++ // previous #EXTINF never got a URL
                    pending = parseExtinf(line)
                    pendingGroup = null
                    if (pending == null) skipped++
                }
                line.startsWith("#EXTGRP:", ignoreCase = true) -> pendingGroup = line.substring(8).trim()
                line.startsWith("#") -> Unit // #EXTVLCOPT, #KODIPROP, comments: ignored for now
                else -> {
                    val url = line
                    if (!isStreamUrl(url)) {
                        skipped++
                        pending = null
                        continue
                    }
                    val info = pending
                    val name = info?.title?.takeIf { it.isNotBlank() }
                        ?: info?.attrs?.get("tvg-name")?.takeIf { it.isNotBlank() }
                        ?: url.substringAfterLast('/').substringBefore('?').ifBlank { url }
                    yield(
                        M3uEntry(
                            name = name,
                            url = url,
                            kind = kindOf(url),
                            tvgId = info?.attrs?.get("tvg-id")?.takeIf { it.isNotBlank() },
                            tvgName = info?.attrs?.get("tvg-name")?.takeIf { it.isNotBlank() },
                            tvgLogo = info?.attrs?.get("tvg-logo")?.takeIf { it.isNotBlank() },
                            groupTitle = (info?.attrs?.get("group-title") ?: pendingGroup)?.takeIf { it.isNotBlank() },
                            tvgChno = info?.attrs?.get("tvg-chno")?.trim()?.toIntOrNull(),
                        ),
                    )
                    pending = null
                    pendingGroup = null
                }
            }
        }
        if (pending != null) skipped++
    }

    private class Extinf(val attrs: Map<String, String>, val title: String)

    /** `#EXTINF:-1 tvg-id="x" group-title="News, UK",Display Name` */
    private fun parseExtinf(line: String): Extinf? {
        val body = line.substringAfter(':', "")
        if (body.isEmpty()) return null
        // The title starts after the first comma that isn't inside quotes.
        var quote: Char? = null
        var titleStart = -1
        for (i in body.indices) {
            val c = body[i]
            when {
                quote != null -> if (c == quote) quote = null
                c == '"' || c == '\'' -> quote = c
                c == ',' -> { titleStart = i; break }
            }
        }
        if (titleStart == -1) return null
        val attrs = parseAttributes(body.substring(0, titleStart))
        return Extinf(attrs, body.substring(titleStart + 1).trim())
    }

    private fun isStreamUrl(s: String): Boolean {
        val scheme = s.substringBefore("://", "").lowercase()
        return scheme in SCHEMES && s.length > scheme.length + 3
    }

    private fun kindOf(url: String): EntryKind {
        val lower = url.lowercase()
        return when {
            "/movie/" in lower -> EntryKind.MOVIE
            "/series/" in lower -> EntryKind.SERIES
            else -> EntryKind.LIVE
        }
    }

    companion object {
        private val SCHEMES = setOf("http", "https", "rtmp", "rtmps", "rtsp", "rtp", "udp", "mms")
        private val ATTR = Regex("""([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))""")

        /** Parses `key="value" key2='v' key3=v` into a map with lowercase keys. */
        fun parseAttributes(s: String): Map<String, String> =
            ATTR.findAll(s).associate { m ->
                val (key, dq, sq, bare) = m.destructured
                key.lowercase() to (dq.ifEmpty { sq.ifEmpty { bare } }).trim()
            }
    }
}
