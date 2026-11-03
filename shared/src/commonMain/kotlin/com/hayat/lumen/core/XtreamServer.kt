package com.hayat.lumen.core

import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.appendEncodedPathSegments
import io.ktor.http.appendPathSegments
import io.ktor.http.encodeURLParameter

/**
 * An Xtream Codes login: server address plus username and password. The shared twin of the
 * Android app's `XtreamLogin` (which is built on OkHttp's HttpUrl), built on Ktor's URL type.
 */
class XtreamServer internal constructor(
    /** e.g. `http://cf.example.com:8080` or `http://example.com/panel`, no trailing slash. */
    internal val base: Url,
    val username: String,
    val password: String,
) {
    /** Just the host, safe to show. */
    val host: String get() = base.host

    /**
     * Lumen's own demo library (https://lumen-tv.github.io/demo, login demo / demo), used for App
     * Review and the store screenshots: free open and public-domain films, shows and test streams.
     * It's plain files on GitHub Pages, which can't answer `player_api.php?action=…`, so each call
     * reads `player_api/<action>.json` (`get_vod_info-<id>.json` for one item) instead, and
     * streams play from each item's `direct_source` link. Only this one address works this way.
     */
    internal val isStaticDemo: Boolean
        get() = base.host == "lumen-tv.github.io" && base.segments.firstOrNull() == "demo"

    /** `player_api.php` with the login, plus `action=<action>` when given. */
    internal fun apiUrl(action: String? = null, extra: Map<String, String> = emptyMap()): String =
        if (isStaticDemo) {
            val file = (listOf(action ?: "account") + extra.values).joinToString("-")
            URLBuilder(base).apply { appendPathSegments("player_api", "$file.json") }.buildString()
        } else URLBuilder(base).apply {
            appendPathSegments("player_api.php")
            // Inside apply, plain `username`/`password` would be URLBuilder's own (user-info) fields.
            parameters.append("username", this@XtreamServer.username)
            parameters.append("password", this@XtreamServer.password)
            if (action != null) parameters.append("action", action)
            extra.forEach { (k, v) -> parameters.append(k, v) }
        }.buildString()

    /** The panel's whole XMLTV guide, `xmltv.php` (holds the login: never log or show it). */
    internal fun xmltvUrl(): String =
        if (isStaticDemo) URLBuilder(base).apply { appendPathSegments("xmltv.xml") }.buildString()
        else URLBuilder(base).apply {
            appendPathSegments("xmltv.php")
            parameters.append("username", this@XtreamServer.username)
            parameters.append("password", this@XtreamServer.password)
        }.buildString()

    /** `/live/<user>/<pass>/<id>.<ext>`. */
    internal fun liveStreamUrl(streamId: String, extension: String): String = mediaUrl("live", streamId, extension)

    /** A film: `/movie/<user>/<pass>/<id>.<ext>`. */
    internal fun movieUrl(streamId: String, extension: String): String = mediaUrl("movie", streamId, extension)

    /** A series episode: `/series/<user>/<pass>/<id>.<ext>`. */
    internal fun episodeUrl(episodeId: String, extension: String): String = mediaUrl("series", episodeId, extension)

    private fun mediaUrl(kind: String, id: String, extension: String): String =
        URLBuilder(base).apply {
            // Encoded like OkHttp's addPathSegment on Android: a '/' in a password becomes %2F.
            val segments = listOf(kind, this@XtreamServer.username, this@XtreamServer.password, "$id.$extension")
            appendEncodedPathSegments(segments.map { it.encodeURLParameter() })
        }.buildString()

    companion object {
        /** Server typed by hand, e.g. `cf.example.com:8080` or `http://cf.example.com/`. Null if unusable. */
        fun of(server: String, username: String, password: String): XtreamServer? {
            if (username.isBlank() || password.isBlank()) return null
            val raw = server.trim().let { if ("://" in it) it else "http://$it" }
            val url = parse(raw) ?: return null
            return XtreamServer(root(url, dropLast = false), username.trim(), password.trim())
        }

        /**
         * Recognises an Xtream playlist link (`…/get.php?username=…&password=…`) or API link
         * (`…/player_api.php?…`) and turns it into a login. Null for any other URL.
         */
        fun fromPlaylistUrl(link: String): XtreamServer? {
            val url = parse(link.trim()) ?: return null
            val file = url.segments.lastOrNull()?.lowercase()
            if (file != "get.php" && file != "player_api.php") return null
            val user = url.parameters["username"]?.takeIf { it.isNotBlank() } ?: return null
            val pass = url.parameters["password"]?.takeIf { it.isNotBlank() } ?: return null
            return XtreamServer(root(url, dropLast = true), user, pass)
        }

        private fun parse(raw: String): Url? {
            if (raw.any { it.isWhitespace() }) return null
            val url = runCatching { Url(raw) }.getOrNull() ?: return null
            if (url.protocol.name != "http" && url.protocol.name != "https") return null
            if (url.host.isBlank() || '.' !in url.host && url.host != "localhost") return null
            return url
        }

        /** Drops query, fragment, login and a trailing slash (and the php file when [dropLast]). */
        private fun root(url: Url, dropLast: Boolean): Url {
            var segments = url.segments
            if (dropLast) segments = segments.dropLast(1)
            return URLBuilder().apply {
                protocol = url.protocol
                host = url.host
                port = url.specifiedPort
                pathSegments = segments.filter { it.isNotEmpty() }
            }.build()
        }
    }
}
