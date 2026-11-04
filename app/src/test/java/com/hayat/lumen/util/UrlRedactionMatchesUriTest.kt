package com.hayat.lumen.util

import com.hayat.lumen.data.m3u.EntryKind
import com.hayat.lumen.data.m3u.M3uEntry
import com.hayat.lumen.data.m3u.StableKeys
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.URI
import java.security.MessageDigest
import kotlin.random.Random

/**
 * UrlRedaction and StableKeys moved to shared code (no java.net.URI or MessageDigest on iOS).
 * Stable keys are hashed from their output, so it must match the old JVM code exactly, or
 * favourites would be lost after an update. These compare against the old implementation.
 */
class UrlRedactionMatchesUriTest {

    private val xtreamPath = Regex("/(live|movie|series|timeshift)/[^/]+/[^/]+/", RegexOption.IGNORE_CASE)

    private fun oldHostOnly(url: String): String =
        runCatching { URI(url.trim()).host }.getOrNull()?.takeIf { it.isNotBlank() } ?: "the server"

    private fun oldWithoutCredentials(url: String): String {
        val uri = runCatching { URI(url.trim()) }.getOrNull() ?: return url.substringBefore('?')
        val host = uri.host ?: return url.substringBefore('?')
        val port = if (uri.port != -1) ":${uri.port}" else ""
        val path = (uri.rawPath ?: "").replace(xtreamPath, "/$1/")
        return "${uri.scheme}://$host$port$path"
    }

    private val samples = listOf(
        "http://cf.example.com:8080/live/user/pass/123.m3u8",
        "http://cf.example.com:80/live/user/pass/123.ts?token=abc#x",
        "https://user:pw@stream.example.com/hls/index.m3u8",
        "http://192.168.1.20:8000/stream",
        "http://my_server.example.com/live/a/b/1.ts",
        "http://host.example.com:/x",
        "http://host-1.example.com./a%20b/c.ts",
        "http://host.example.com/a b.ts",
        "http://host.example.com/bad%zz",
        "http://host.example.com/{x}/1.ts",
        "http://host.example.com/a|b",
        "http://hôst.example.com/chaîne.ts",
        "http://host.example.com/chaîne/ünï.ts",
        "rtmp://live.example.com/app/stream",
        "udp://@239.0.0.1:1234",
        "http://1host.example.com/x",
        "http://example.123/x",
        "http://-bad.example.com/x",
        "http://localhost:8080/x",
        "http://host.example.com",
        "http://host.example.com?x=1",
        "http://host.example.com#frag",
        "http://h.example.com/a#b#c",
        "http:",
        "http://",
        "not a url",
        "relative/path.ts",
        "mailto:someone@example.com",
        "http://[::1]:8080/x",
        "1http://h.example.com/x",
        "  http://h.example.com/padded  ",
        "http://h.example.com:99999/x",
        "http://h.example.com:8o/x",
        "http://u@h.example.com:81/x/y/",
        "http://h.example.com/live/u/p/x/y/1.ts",
        "http://h.example.com/MOVIE/u/p/9.mkv",
        "",
    )

    @Test
    fun matchesTheOldUriCode() {
        for (url in samples) {
            assertEquals("hostOnly($url)", oldHostOnly(url), UrlRedaction.hostOnly(url))
            assertEquals("withoutCredentials($url)", oldWithoutCredentials(url), UrlRedaction.withoutCredentials(url))
        }
    }

    @Test
    fun matchesOnRandomUrls() {
        val random = Random(7)
        val pieces = listOf(
            "http://", "https://", "h.example.com", "a_b.example.com", "1.2.3.4", ":8080", ":", "/live/", "/u/", "p",
            "/1.ts", "?q=1", "#f", "@", "%20", "%2", " ", "é", "|", "-", ".", "x", "/", "//", "[", "]",
        )
        repeat(20_000) {
            val url = buildString { repeat(random.nextInt(1, 9)) { append(pieces.random(random)) } }
            assertEquals("hostOnly($url)", oldHostOnly(url), UrlRedaction.hostOnly(url))
            assertEquals("withoutCredentials($url)", oldWithoutCredentials(url), UrlRedaction.withoutCredentials(url))
        }
    }

    @Test
    fun stableKeysMatchMessageDigest() {
        fun old(entry: M3uEntry): String {
            val name = StableKeys.normaliseName(entry.name)
            val s = "$name|${oldWithoutCredentials(entry.url)}"
            return "h:" + MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }.take(16)
        }
        for (name in listOf("BBC One", "Chaîne Française ★", "", "x".repeat(200), "日本のテレビ")) {
            val entry = M3uEntry(name, "http://h.example.com/live/u/p/1.ts", EntryKind.LIVE, null, null, null, null, null)
            assertEquals(old(entry), StableKeys().keyFor(entry))
        }
    }
}
