package com.hayat.lumen.data.vod

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/** An episode's description and still from TVmaze, for episodes the provider sends without them. */
data class EpisodeNote(val summary: String?, val image: String?)

/**
 * TVmaze (api.tvmaze.com): a free TV database with no key or sign-up. Many of Hayat's provider's
 * episodes come without a description (2026-11-03), so the series page fills the blanks from here.
 * Its data is CC BY-SA, so the series page says where the text came from.
 *
 * The show is found by its IMDb id when OMDb gave one, else by name (and first year); then all its
 * episodes come in one request. Kept in memory, and in the app's cache folder for a week. Same
 * approach as the iOS app's `EpisodeNotes.swift`.
 */
class EpisodeNotesClient(http: OkHttpClient, private val cacheDir: File) {
    // Short timeouts: the page is already showing; the descriptions just appear when they arrive.
    private val http = http.newBuilder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    private val cache = object : LinkedHashMap<String, Map<String, EpisodeNote>>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Map<String, EpisodeNote>>) = size > 50
    }

    /**
     * Notes for a show's episodes, keyed [key] (`"<season>|<episode>"`). Empty when TVmaze doesn't
     * know the show or can't be reached; a miss isn't asked again until the app restarts.
     */
    suspend fun notes(title: String, year: Int?, imdbId: String?): Map<String, EpisodeNote> = withContext(Dispatchers.IO) {
        val cacheKey = imdbId ?: "${title.lowercase()}|${year ?: ""}"
        synchronized(cache) { cache[cacheKey] }?.let { return@withContext it }
        val file = File(cacheDir, "tvmaze-" + cacheKey.lowercase().map { if (it.isLetterOrDigit()) it else '_' }.joinToString("").take(80) + ".json")
        val saved = runCatching { if (file.exists()) parseSaved(file.readText()) else null }.getOrNull()
        if (saved != null && System.currentTimeMillis() - file.lastModified() < WEEK_MS) {
            synchronized(cache) { cache[cacheKey] = saved }
            return@withContext saved
        }
        val fresh = showId(title, year, imdbId)
            ?.let { get("https://api.tvmaze.com/shows/$it/episodes") }
            ?.let(::parseEpisodes)
        // An old copy beats nothing.
        val notes = fresh ?: saved ?: emptyMap()
        synchronized(cache) { cache[cacheKey] = notes }
        if (fresh != null) runCatching { cacheDir.mkdirs(); file.writeText(save(fresh)) }
        notes
    }

    private fun showId(title: String, year: Int?, imdbId: String?): Int? {
        // TVmaze answers the IMDb lookup with a redirect to the show, which OkHttp follows.
        imdbId?.let { get("https://api.tvmaze.com/lookup/shows?imdb=$it") }
            ?.let { runCatching { JSONObject(it).optInt("id", 0) }.getOrNull() }
            ?.takeIf { it > 0 }
            ?.let { return it }
        val url = "https://api.tvmaze.com/search/shows".toHttpUrl().newBuilder().addQueryParameter("q", title).build().toString()
        return get(url)?.let { pickShow(it, title, year) }
    }

    private fun get(url: String): String? = try {
        http.newCall(Request.Builder().url(url).build()).execute().use { r -> if (r.isSuccessful) r.body.string() else null }
    } catch (e: IOException) {
        null
    }

    companion object {
        private const val WEEK_MS = 7L * 24 * 3600 * 1000

        fun key(season: Int, episode: Int) = "$season|$episode"

        /** `[{"season":1,"number":1,"summary":"<p>…</p>","image":{"medium":"https://…"}},…]` */
        fun parseEpisodes(body: String): Map<String, EpisodeNote>? = runCatching {
            val list = JSONArray(body)
            buildMap {
                for (i in 0 until list.length()) {
                    val o = list.optJSONObject(i) ?: continue
                    val season = o.optInt("season", -1)
                    val number = o.optInt("number", -1) // null for specials
                    if (season < 0 || number < 0) continue
                    val summary = o.optStringOrNull("summary")?.let(::plainText)
                    val image = o.optJSONObject("image")?.optStringOrNull("medium")
                    if (summary != null || image != null) put(key(season, number), EpisodeNote(summary, image))
                }
            }
        }.getOrNull()

        /**
         * From a name search: the show with the same name (ignoring case and punctuation) and, when
         * known, the same first year, because a remake shares the name.
         */
        fun pickShow(body: String, title: String, year: Int?): Int? = runCatching {
            val results = JSONArray(body)
            val wanted = simple(title)
            val named = (0 until results.length())
                .mapNotNull { results.optJSONObject(it)?.optJSONObject("show") }
                .filter { simple(it.optString("name")) == wanted }
            val show = if (year != null) {
                named.firstOrNull { it.optStringOrNull("premiered")?.take(4) == year.toString() } ?: named.singleOrNull()
            } else {
                named.firstOrNull()
            }
            show?.optInt("id", 0)?.takeIf { it > 0 }
        }.getOrNull()

        /** TVmaze's summaries are small HTML (`<p>Logan <b>considers</b>…</p>`). */
        fun plainText(html: String): String? {
            var text = html.replace(Regex("<[^>]+>"), "")
            for ((entity, char) in listOf("&quot;" to "\"", "&#39;" to "'", "&apos;" to "'", "&lt;" to "<", "&gt;" to ">", "&nbsp;" to " ", "&amp;" to "&")) {
                text = text.replace(entity, char)
            }
            return text.trim().ifEmpty { null }
        }

        private fun simple(name: String) = name.lowercase().filter { it.isLetterOrDigit() }

        private fun save(notes: Map<String, EpisodeNote>) = JSONObject().apply {
            notes.forEach { (k, n) -> put(k, JSONObject().put("summary", n.summary ?: JSONObject.NULL).put("image", n.image ?: JSONObject.NULL)) }
        }.toString()

        private fun parseSaved(body: String): Map<String, EpisodeNote> {
            val json = JSONObject(body)
            return json.keys().asSequence().associateWith { k ->
                val o = json.getJSONObject(k)
                EpisodeNote(o.optStringOrNull("summary"), o.optStringOrNull("image"))
            }
        }

        // optString turns JSON null into the text "null".
        private fun JSONObject.optStringOrNull(name: String): String? =
            if (isNull(name)) null else optString(name).ifBlank { null }
    }
}
