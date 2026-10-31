package com.hayat.lumen.data.skip

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/** A part of an episode that can be skipped. Times in milliseconds from the start of the file. */
data class SkipSegment(val kind: Kind, val startMs: Long, val endMs: Long?) {
    enum class Kind { INTRO, RECAP, CREDITS }
}

/** Which show and episode to look up. Either id is enough; both give two chances. */
data class EpisodeRef(
    val tmdbId: String?,
    val imdbId: String?,
    val season: Int,
    val episode: Int,
    /** The episode's length, which lets SkipDB shift times for a cut that's a few seconds longer. */
    val durationSecs: Long?,
)

/**
 * Intro, recap and end-credit times per episode, from free community databases (providers don't
 * send any). Shows with a cold open have the intro minutes in, so it has to be per episode.
 *
 * - TheIntroDB (theintrodb.org), by TMDB id: most entries.
 * - IntroDB (introdb.app), by IMDb id.
 * - SkipDB (skipdb.tv, ODbL data), by IMDb id: fills gaps.
 *
 * All anonymous reads, no key. One small request per episode, made while the video buffers;
 * nothing waits for it, and an empty answer just means no button.
 */
class SkipTimesClient(http: OkHttpClient) {
    // Short timeouts: a slow database must never delay anything the viewer sees.
    private val http = http.newBuilder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .build()

    private val cache = object : LinkedHashMap<String, List<SkipSegment>>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<SkipSegment>>) = size > 200
    }
    private val tmdbSearch = object : LinkedHashMap<String, String>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>) = size > 100
    }

    /** The segments for one episode, best source first per kind. Empty when nobody has it. */
    suspend fun episode(ref: EpisodeRef): List<SkipSegment> {
        if (ref.tmdbId == null && ref.imdbId == null) return emptyList()
        val key = "${ref.tmdbId}|${ref.imdbId}|${ref.season}|${ref.episode}"
        synchronized(cache) { cache[key] }?.let { return it }
        var reached = false
        val found = coroutineScope {
            val a = async { ref.tmdbId?.let { get(theIntroDb(it, ref)) }?.also { reached = true }?.let(::parseTheIntroDb) }
            val b = async { ref.imdbId?.let { get(introDb(it, ref)) }?.also { reached = true }?.let(::parseIntroDb) }
            val c = async { ref.imdbId?.let { get(skipDb(it, ref)) }?.also { reached = true }?.let(::parseSkipDb) }
            SkipPick.merge(listOf(a.await().orEmpty(), b.await().orEmpty(), c.await().orEmpty()))
        }
        // A network blip isn't cached, so the next episode (or a retry) asks again.
        if (reached) synchronized(cache) { cache[key] = found }
        return found
    }

    /** Finds a show's TMDB id by name (SkipDB's open title search), for panels that don't send one. */
    suspend fun tmdbIdFor(name: String, year: Int?): String? {
        val key = "${name.lowercase()}|${year ?: ""}"
        synchronized(tmdbSearch) { tmdbSearch[key] }?.let { return it.ifEmpty { null } }
        val url = "https://skipdb.tv/api/titles/search".toHttpUrl().newBuilder().addQueryParameter("q", name).build().toString()
        val body = get(url) ?: return null
        val id = runCatching { pickSearchResult(JSONObject(body).optJSONArray("results"), name, year) }.getOrNull()
        synchronized(tmdbSearch) { tmdbSearch[key] = id.orEmpty() }
        return id
    }

    private suspend fun get(url: String): String? = withContext(Dispatchers.IO) {
        try {
            http.newCall(Request.Builder().url(url).build()).execute().use { r ->
                when {
                    r.isSuccessful -> r.body.string()
                    r.code == 404 -> "" // known "not in the database": cache it
                    else -> null
                }
            }
        } catch (e: IOException) {
            null
        }
    }

    private fun theIntroDb(tmdb: String, ref: EpisodeRef) = "https://api.theintrodb.org/v2/media".toHttpUrl().newBuilder()
        .addQueryParameter("tmdb_id", tmdb)
        .addQueryParameter("season", ref.season.toString())
        .addQueryParameter("episode", ref.episode.toString())
        .build().toString()

    private fun introDb(imdb: String, ref: EpisodeRef) = "https://api.introdb.app/segments".toHttpUrl().newBuilder()
        .addQueryParameter("imdb_id", imdb)
        .addQueryParameter("season", ref.season.toString())
        .addQueryParameter("episode", ref.episode.toString())
        .build().toString()

    private fun skipDb(imdb: String, ref: EpisodeRef) = "https://api.skipdb.tv/api/segments".toHttpUrl().newBuilder()
        .addQueryParameter("imdb_id", imdb)
        .addQueryParameter("season", ref.season.toString())
        .addQueryParameter("episode", ref.episode.toString())
        .apply { ref.durationSecs?.let { addQueryParameter("duration", it.toString()) } }
        .build().toString()

    companion object {
        /** `{"intro":[{"start_ms":314568,"end_ms":330969}],"recap":[…],"credits":[{"start_ms":…,"end_ms":null}]}` */
        fun parseTheIntroDb(body: String): List<SkipSegment> = runCatching {
            if (body.isBlank()) return emptyList()
            val json = JSONObject(body)
            buildList {
                for ((field, kind) in listOf("intro" to SkipSegment.Kind.INTRO, "recap" to SkipSegment.Kind.RECAP, "credits" to SkipSegment.Kind.CREDITS)) {
                    val list = json.optJSONArray(field) ?: continue
                    list.optJSONObject(0)?.let { o -> segment(kind, o.ms("start_ms"), o.ms("end_ms"))?.let(::add) }
                }
            }
        }.getOrDefault(emptyList())

        /** `{"intro":{"start_ms":…,"end_ms":…},"recap":null,"outro":{…}}` */
        fun parseIntroDb(body: String): List<SkipSegment> = runCatching {
            if (body.isBlank()) return emptyList()
            val json = JSONObject(body)
            buildList {
                for ((field, kind) in listOf("intro" to SkipSegment.Kind.INTRO, "recap" to SkipSegment.Kind.RECAP, "outro" to SkipSegment.Kind.CREDITS)) {
                    json.optJSONObject(field)?.let { o -> segment(kind, o.ms("start_ms"), o.ms("end_ms"))?.let(::add) }
                }
            }
        }.getOrDefault(emptyList())

        /** `{"segments":{"intro":{"start_ms":…,"end_ms":…,"match":"exact"},…}}`; "out-of-range" matches are left out. */
        fun parseSkipDb(body: String): List<SkipSegment> = runCatching {
            if (body.isBlank()) return emptyList()
            val segments = JSONObject(body).optJSONObject("segments") ?: return emptyList()
            buildList {
                for ((field, kind) in listOf("intro" to SkipSegment.Kind.INTRO, "recap" to SkipSegment.Kind.RECAP, "outro" to SkipSegment.Kind.CREDITS)) {
                    val o = segments.optJSONObject(field) ?: continue
                    if (o.optString("match") == "out-of-range") continue
                    segment(kind, o.ms("start_ms"), o.ms("end_ms"))?.let(::add)
                }
            }
        }.getOrDefault(emptyList())

        internal fun pickSearchResult(results: JSONArray?, name: String, year: Int?): String? {
            results ?: return null
            val wanted = name.lowercase().filter(Char::isLetterOrDigit)
            var best: String? = null
            for (i in 0 until results.length()) {
                val r = results.optJSONObject(i) ?: continue
                if (r.optString("mediaType") != "series") continue
                val id = r.opt("tmdbId")?.toString()?.takeIf { it.isNotEmpty() && it != "null" } ?: continue
                val sameName = r.optString("name").lowercase().filter(Char::isLetterOrDigit) == wanted
                val ry = r.optInt("year", 0)
                if (sameName && (year == null || ry == 0 || kotlin.math.abs(ry - year) <= 1)) return id
                if (best == null && sameName) best = id
            }
            return best
        }

        private fun JSONObject.ms(name: String): Long? = if (isNull(name)) null else optLong(name, -1).takeIf { it >= 0 }

        // "No intro" is sent as 0–0; segments under 5 s are noise.
        private fun segment(kind: SkipSegment.Kind, start: Long?, end: Long?): SkipSegment? {
            start ?: return null
            if (end != null && end - start < 5_000) return null
            return SkipSegment(kind, start, end)
        }
    }
}
