package com.hayat.lumen.util

/**
 * Playlist and stream URLs routinely carry credentials (query params, user:pass@,
 * or Xtream-style /live/<user>/<pass>/ paths). Nothing that might be logged or
 * shown in an error message should contain them.
 */
object UrlRedaction {

    private val xtreamPath = Regex("/(live|movie|series|timeshift)/[^/]+/[^/]+/", RegexOption.IGNORE_CASE)

    /** Safe for logs and error messages: just the host, e.g. "cf.example.com". */
    fun hostOnly(url: String): String =
        SimpleUri.parse(url.trim())?.host?.takeIf { it.isNotBlank() } ?: "the server"

    /**
     * The URL with credentials removed but the stream identity kept, so it is stable
     * when a password changes: drops user-info, query and fragment, and collapses
     * Xtream `/live/<user>/<pass>/123.ts` to `/live/123.ts`.
     */
    fun withoutCredentials(url: String): String {
        val uri = SimpleUri.parse(url.trim()) ?: return url.substringBefore('?')
        val host = uri.host ?: return url.substringBefore('?')
        val port = if (uri.port != null) ":${uri.port}" else ""
        val path = uri.rawPath.replace(xtreamPath, "/$1/")
        return "${uri.scheme}://$host$port$path"
    }
}

/**
 * The parts of a URL that [UrlRedaction] needs, read the way `java.net.URI` reads them (this
 * used to be `URI`, which iOS doesn't have). It must give the same answers, because stable
 * channel keys are hashed from them: a different answer would lose favourites on Android.
 *
 * - null when `URI` would throw (spaces, bad `%` escapes, other illegal characters);
 * - [host] null when `URI` can't read a host name (e.g. `my_server`), as `URI.getHost()` does.
 */
internal class SimpleUri(val scheme: String?, val host: String?, val port: Int?, val rawPath: String) {
    companion object {
        // What URI accepts: unreserved, reserved and '%' (checked below), plus any non-ASCII
        // character that isn't a control or space character ("other" in its grammar).
        private fun legal(c: Char): Boolean = when {
            c.code > 0x7F -> !c.isISOControl() && !c.isWhitespace()
            c.isLetterOrDigit() -> true
            else -> c in "-_.!~*'();/?:@&=+$,%#"
        }

        private val scheme = Regex("^[A-Za-z][A-Za-z0-9+.-]*$")
        private val hostname = Regex(
            "^(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)*[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.?$",
        )
        private val ipv4 = Regex("^\\d{1,3}(\\.\\d{1,3}){3}$")
        private val hex = "0123456789abcdefABCDEF"

        private fun ipv6(s: String): Boolean {
            val halves = s.split("::")
            if (halves.size > 2) return false
            fun groups(part: String): Int? {
                if (part.isEmpty()) return 0
                val items = part.split(':')
                var count = 0
                for ((i, g) in items.withIndex()) {
                    count += when {
                        i == items.lastIndex && ipv4.matches(g) -> 2
                        g.length in 1..4 && g.all { it in hex } -> 1
                        else -> return null
                    }
                }
                return count
            }
            val left = groups(halves[0]) ?: return false
            if (halves.size == 1) return left == 8
            if (halves[0].isNotEmpty() && ipv4.matches(halves[0].substringAfterLast(':'))) return false
            val right = groups(halves[1]) ?: return false
            return left + right <= 7
        }

        /** True when the bracket at [i] belongs to a `//[v6]` host (one '[' then one ']'). */
        private fun inIpv6Host(s: String, i: Int): Boolean {
            val start = s.indexOf("//")
            if (start == -1) return false
            val authorityEnd = s.indexOfAny(charArrayOf('/', '?', '#'), start + 2).let { if (it == -1) s.length else it }
            if (i !in start + 2 until authorityEnd) return false
            val hostPort = s.substring(start + 2, authorityEnd).substringAfterLast('@')
            val open = authorityEnd - hostPort.length
            return hostPort.startsWith('[') && hostPort.count { it == '[' } == 1 && hostPort.count { it == ']' } == 1 &&
                hostPort.indexOf(']') > 0 && (i == open || i == open + hostPort.indexOf(']'))
        }

        fun parse(s: String): SimpleUri? {
            if (s.isEmpty()) return null
            // '[' and ']' are only allowed around an IPv6 host, and in the query and fragment.
            val queryStart = s.indexOfAny(charArrayOf('?', '#')).let { if (it == -1) s.length else it }
            for (i in s.indices) {
                val c = s[i]
                if (c == '[' || c == ']') {
                    if (i < queryStart && !inIpv6Host(s, i)) return null
                } else if (!legal(c)) return null
            }
            for (i in s.indices) {
                if (s[i] == '%' && (i + 2 >= s.length || s[i + 1] !in hex || s[i + 2] !in hex)) return null
            }
            if (s.count { it == '#' } > 1) return null

            val colon = s.indexOf(':')
            val firstSlash = s.indexOfAny(charArrayOf('/', '?', '#'))
            val schemeName = if (colon > 0 && (firstSlash == -1 || colon < firstSlash)) s.substring(0, colon) else null
            if (schemeName != null && !scheme.matches(schemeName)) return null
            val rest = if (schemeName != null) s.substring(colon + 1) else s
            if (!rest.startsWith("//")) {
                // "mailto:x" or a relative path: no host. A scheme with nothing after it is illegal.
                if (schemeName != null && rest.isEmpty()) return null
                return SimpleUri(schemeName, null, null, rest.substringBefore('?').substringBefore('#'))
            }
            val afterSlashes = rest.substring(2)
            val authorityEnd = afterSlashes.indexOfAny(charArrayOf('/', '?', '#')).let { if (it == -1) afterSlashes.length else it }
            val authority = afterSlashes.substring(0, authorityEnd)
            val path = afterSlashes.substring(authorityEnd).substringBefore('?').substringBefore('#')
            // A second '@' can't be in the user-info: URI then reads no host at all.
            if (authority.count { it == '@' } > 1) return SimpleUri(schemeName, null, null, path)
            val hostPort = authority.substringAfterLast('@')
            if (hostPort.startsWith('[')) {
                val close = hostPort.indexOf(']')
                val literal = hostPort.substring(1, close)
                if (!ipv6(literal)) return null
                val after = hostPort.substring(close + 1)
                if (after.isNotEmpty() && (!after.startsWith(':') || !after.drop(1).all { it.isDigit() })) return null
                return SimpleUri(schemeName, hostPort.substring(0, close + 1), after.drop(1).toIntOrNull(), path)
            }
            val portText = if (':' in hostPort) hostPort.substringAfterLast(':') else ""
            val hostText = if (':' in hostPort) hostPort.substringBeforeLast(':') else hostPort
            val validServer = (hostname.matches(hostText) || ipv4.matches(hostText)) &&
                portText.all { it.isDigit() } && ':' !in hostText
            if (!validServer) {
                // URI falls back to a "registry-based" authority: no host, no port.
                return SimpleUri(schemeName, null, null, path)
            }
            val port = portText.takeIf { it.isNotEmpty() }?.toIntOrNull()
            return SimpleUri(schemeName, hostText, port, path)
        }
    }
}
