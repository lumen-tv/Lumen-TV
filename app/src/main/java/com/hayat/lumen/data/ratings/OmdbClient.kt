package com.hayat.lumen.data.ratings

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.IOException

enum class KeyCheck { WORKS, REJECTED, UNREACHABLE }

/** Scores for one title. Each is null when OMDb doesn't have it. */
data class Ratings(
    /** "7.5" (out of 10). */
    val imdb: String?,
    /** "94%". */
    val rottenTomatoes: String?,
    /** The age rating, e.g. "PG-13" or "12A". */
    val age: String?,
    /** How many people rated it on IMDb, e.g. 32756. */
    val imdbVotes: Int? = null,
    /** "tt0903747"; also used to look up intro times. */
    val imdbId: String? = null,
) {
    val isEmpty get() = imdb == null && rottenTomatoes == null && age == null
}

/** OMDb (omdbapi.com): IMDb, Rotten Tomatoes and age ratings, with the user's own free key. */
class OmdbClient(private val http: OkHttpClient) {
    /** Looks up one well-known film to see whether OMDb accepts [key]. */
    suspend fun check(key: String): KeyCheck = withContext(Dispatchers.IO) {
        val url = BASE.toHttpUrl().newBuilder()
            .addQueryParameter("apikey", key.trim())
            .addQueryParameter("i", "tt0111161")
            .build()
        try {
            http.newCall(Request.Builder().url(url).build()).execute().use { response ->
                val body = response.body.string()
                when {
                    response.code == 401 || "Invalid API key" in body -> KeyCheck.REJECTED
                    response.isSuccessful && "\"Response\":\"True\"" in body -> KeyCheck.WORKS
                    else -> KeyCheck.UNREACHABLE
                }
            }
        } catch (e: IOException) {
            KeyCheck.UNREACHABLE
        }
    }

    // Titles looked up this session (hits and misses), so going back to a film costs nothing.
    // The free key allows 1,000 lookups a day.
    private val cache = object : LinkedHashMap<String, Ratings>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Ratings>) = size > 300
    }

    /**
     * IMDb, Rotten Tomatoes and age rating for a film or series, found by title and year.
     * Null when there's no key, OMDb can't be reached or doesn't know the title.
     */
    suspend fun ratings(key: String?, title: String, year: Int?, series: Boolean): Ratings? {
        if (key.isNullOrBlank()) return null
        val id = "${if (series) "s" else "m"}|${title.lowercase()}|${year ?: ""}"
        synchronized(cache) { cache[id] }?.let { return it.takeUnless { r -> r.isEmpty } }
        val found = withContext(Dispatchers.IO) {
            val url = BASE.toHttpUrl().newBuilder()
                .addQueryParameter("apikey", key.trim())
                .addQueryParameter("t", title)
                .addQueryParameter("type", if (series) "series" else "movie")
                .apply { if (year != null) addQueryParameter("y", year.toString()) }
                .build()
            try {
                http.newCall(Request.Builder().url(url).build()).execute().use { response ->
                    if (!response.isSuccessful) return@withContext null
                    parse(response.body.string())
                }
            } catch (e: IOException) {
                null
            }
        } ?: return null // not cached: a network blip shouldn't hide scores for the whole session
        synchronized(cache) { cache[id] = found }
        return found.takeUnless { it.isEmpty }
    }

    private fun parse(body: String): Ratings? = runCatching {
        val json = JSONObject(body)
        if (json.optString("Response") != "True") return@runCatching Ratings(null, null, null)
        fun clean(v: String?) = v?.trim()?.takeIf { it.isNotEmpty() && it != "N/A" }
        val sources = json.optJSONArray("Ratings")
        var tomatoes: String? = null
        if (sources != null) {
            for (i in 0 until sources.length()) {
                val r = sources.optJSONObject(i) ?: continue
                if (r.optString("Source") == "Rotten Tomatoes") tomatoes = clean(r.optString("Value"))
            }
        }
        Ratings(
            imdb = clean(json.optString("imdbRating")),
            rottenTomatoes = tomatoes,
            age = clean(json.optString("Rated"))?.takeUnless { it == "Not Rated" || it == "Unrated" },
            imdbVotes = clean(json.optString("imdbVotes"))?.filter { it.isDigit() }?.toIntOrNull(), // "32,756"
            imdbId = clean(json.optString("imdbID"))?.takeIf { it.startsWith("tt") },
        )
    }.getOrNull()

    private companion object {
        const val BASE = "https://www.omdbapi.com/"
    }
}
