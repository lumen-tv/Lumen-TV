package com.hayat.lumen.core

import kotlinx.serialization.Serializable

/** One programme in the TV guide. Times are epoch seconds (Swift: `Int64`). */
@Serializable
class Programme(
    val start: Long,
    val stop: Long,
    val title: String,
    val description: String?,
) {
    /** 0…1 through the programme at [now] (epoch seconds). */
    fun progress(now: Long): Double =
        if (stop <= start) 0.0 else ((now - start).toDouble() / (stop - start)).coerceIn(0.0, 1.0)
}

/** What's on now and next on one channel. Either may be missing. */
class NowNext(val now: Programme?, val next: Programme?)

/**
 * A playlist's TV guide: programmes per channel, keyed by the channel's `tvg-id` (lowercased,
 * as on the TV app), each list sorted by start time. Only now − 2 h … now + 36 h is kept.
 */
class Guide internal constructor(internal val byChannel: Map<String, List<Programme>>) {

    /** How many of the playlist's channels have guide info. */
    val channelCount: Int get() = byChannel.size

    fun hasGuide(tvgId: String?): Boolean = key(tvgId)?.let { byChannel.containsKey(it) } == true

    /** Every stored programme of the channel, in order. */
    fun schedule(tvgId: String?): List<Programme> = key(tvgId)?.let { byChannel[it] }.orEmpty()

    /** Programmes that overlap [from] … [to] (epoch seconds), in order. */
    fun between(tvgId: String?, from: Long, to: Long): List<Programme> =
        schedule(tvgId).filter { it.stop > from && it.start < to }

    fun nowNext(tvgId: String?, now: Long): NowNext? {
        val list = schedule(tvgId)
        if (list.isEmpty()) return null
        val current = list.firstOrNull { it.start <= now && now < it.stop }
        val next = list.firstOrNull { it.start >= (current?.stop ?: now) }
        if (current == null && next == null) return null
        return NowNext(current, next)
    }

    private fun key(tvgId: String?): String? = tvgId?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
}

/**
 * Reads XMLTV `<programme>` elements from bytes fed in pieces (a provider's guide can be
 * hundreds of MB, so it's never held whole). Keeps only [wanted] channels (lowercased tvg-ids)
 * and programmes overlapping [from] … [to].
 *
 * Hand-rolled rather than a full XML parser: Kotlin has no common XML library, and XMLTV is a
 * flat, simple format. Handles `'` or `"` attributes, entities, CDATA, and UTF-8 split between
 * pieces.
 */
internal class XmltvReader(
    private val wanted: Set<String>,
    private val from: Long,
    private val to: Long,
) {
    private val text = StringBuilder()
    private var carry = ByteArray(0)
    private val out = HashMap<String, MutableList<Programme>>()

    var skipped = 0
        private set
    var seen = 0
        private set

    fun feed(bytes: ByteArray, count: Int) {
        val all = if (carry.isEmpty()) bytes.copyOf(count) else carry + bytes.copyOf(count)
        val complete = completeUtf8Length(all)
        text.append(all.decodeToString(0, complete))
        carry = all.copyOfRange(complete, all.size)
        drain()
    }

    fun finish(): Guide {
        drain()
        return Guide(out.mapValues { (_, list) -> list.sortedBy { it.start }.distinctBy { it.start } })
    }

    private fun drain() {
        var pos = 0
        while (true) {
            val open = findOpen(pos)
            if (open < 0) {
                // Keep a short tail: "<programme" may be split across pieces.
                pos = maxOf(pos, text.length - OPEN.length)
                break
            }
            val close = text.indexOf(CLOSE, open)
            if (close < 0) {
                pos = open
                break
            }
            read(text.substring(open, close))
            pos = close + CLOSE.length
        }
        if (pos > 0) text.deleteRange(0, pos)
    }

    /** The next `<programme` followed by whitespace or `>` (not `<programmes`). */
    private fun findOpen(from: Int): Int {
        var at = from
        while (true) {
            val i = text.indexOf(OPEN, at)
            // Not found, or found at the very end where the next character hasn't arrived yet.
            if (i < 0 || i + OPEN.length >= text.length) return -1
            val c = text[i + OPEN.length]
            if (c == '>' || c.isWhitespace()) return i
            at = i + 1
        }
    }

    private fun read(element: String) {
        seen++
        val tagEnd = element.indexOf('>')
        if (tagEnd < 0) { skipped++; return }
        val tag = element.substring(0, tagEnd)
        val attrs = ATTR.findAll(tag).associate { it.groupValues[1] to it.groupValues[3] }
        val channel = attrs["channel"]?.let(::decodeEntities)?.trim()?.lowercase()
        if (channel.isNullOrEmpty() || channel !in wanted) return
        val start = attrs["start"]?.let(::parseTime)
        val stop = attrs["stop"]?.let(::parseTime)
        if (start == null || stop == null || stop <= start) { skipped++; return }
        if (stop <= from || start >= to) return
        val body = element.substring(tagEnd + 1)
        val title = TITLE.find(body)?.groupValues?.get(1)?.let(::text)?.takeIf { it.isNotEmpty() }
        if (title == null) { skipped++; return }
        val desc = DESC.find(body)?.groupValues?.get(1)?.let(::text)?.takeIf { it.isNotEmpty() }?.take(500)
        out.getOrPut(channel) { ArrayList() } += Programme(start, stop, title, desc)
    }

    private fun text(raw: String): String {
        val trimmed = raw.trim()
        val inner = if (trimmed.startsWith("<![CDATA[") && trimmed.endsWith("]]>")) {
            trimmed.substring(9, trimmed.length - 3)
        } else {
            decodeEntities(trimmed)
        }
        return inner.trim().replace(SPACES, " ")
    }

    companion object {
        private const val OPEN = "<programme"
        private const val CLOSE = "</programme>"
        private val ATTR = Regex("""([A-Za-z_:-]+)\s*=\s*(["'])(.*?)\2""")
        // [\s\S] instead of '.', which doesn't cross newlines (common Kotlin has no DOTALL).
        private val TITLE = Regex("""<title(?:\s[^>]*)?>([\s\S]*?)</title>""")
        private val DESC = Regex("""<desc(?:\s[^>]*)?>([\s\S]*?)</desc>""")
        private val SPACES = Regex("""\s+""")
        private val ENTITY = Regex("""&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);""")

        fun decodeEntities(raw: String): String {
            if ('&' !in raw) return raw
            return ENTITY.replace(raw) { m ->
                val name = m.groupValues[1]
                when {
                    name.startsWith("#x") || name.startsWith("#X") -> name.substring(2).toIntOrNull(16)?.let(::codePoint)
                    name.startsWith("#") -> name.substring(1).toIntOrNull()?.let(::codePoint)
                    else -> NAMED[name]
                } ?: m.value
            }
        }

        private val NAMED = mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ")

        private fun codePoint(cp: Int): String? = when {
            cp < 0 || cp > 0x10FFFF -> null
            cp < 0x10000 -> cp.toChar().toString()
            else -> {
                val v = cp - 0x10000
                charArrayOf((0xD800 + (v shr 10)).toChar(), (0xDC00 + (v and 0x3FF)).toChar()).concatToString()
            }
        }

        /** How many leading bytes form whole UTF-8 characters (the rest waits for the next piece). */
        fun completeUtf8Length(bytes: ByteArray): Int {
            val n = bytes.size
            // Look back at most 3 bytes for the start of the last character.
            for (back in 1..minOf(3, n)) {
                val b = bytes[n - back].toInt() and 0xFF
                if (b and 0xC0 == 0x80) continue // continuation byte
                val need = when {
                    b and 0x80 == 0 -> 1
                    b and 0xE0 == 0xC0 -> 2
                    b and 0xF0 == 0xE0 -> 3
                    b and 0xF8 == 0xF0 -> 4
                    else -> 1
                }
                return if (need > back) n - back else n
            }
            return n
        }

        /**
         * XMLTV time, e.g. `20261026220000 +0100`, to epoch seconds. Seconds and minutes may be
         * missing; no offset means UTC. Null if unreadable. (Same rules as the TV app's parser.)
         */
        fun parseTime(raw: String): Long? {
            val text = raw.trim()
            val digits = text.takeWhile { it.isDigit() }
            if (digits.length < 8) return null
            fun part(from: Int, len: Int) = if (digits.length >= from + len) digits.substring(from, from + len).toInt() else 0
            val rest = text.substring(digits.length).trim()
            val offsetMinutes = if (rest.length >= 5 && (rest[0] == '+' || rest[0] == '-') && rest.substring(1, 5).all { it.isDigit() }) {
                val m = rest.substring(1, 3).toInt() * 60 + rest.substring(3, 5).toInt()
                if (rest[0] == '-') -m else m
            } else 0
            val year = part(0, 4); val month = part(4, 2); val day = part(6, 2)
            val hour = part(8, 2); val minute = part(10, 2); val second = part(12, 2)
            if (month !in 1..12 || day !in 1..31 || hour > 23 || minute > 59 || second > 60) return null
            return daysFromCivil(year, month, day) * 86_400L + hour * 3600 + minute * 60 + second - offsetMinutes * 60L
        }

        /** Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm). */
        private fun daysFromCivil(y0: Int, m: Int, d: Int): Long {
            val y = if (m <= 2) y0 - 1 else y0
            val era = (if (y >= 0) y else y - 399) / 400
            val yoe = y - era * 400
            val doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1
            val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146_097L + doe - 719_468L
        }
    }
}
