package com.hayat.lumen.data.xtream

import android.util.JsonReader
import android.util.JsonToken
import com.hayat.lumen.data.ImportException
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.Closeable
import java.io.IOException

data class XtreamAccount(val outputExtension: String)

data class XtreamCategory(val id: String, val name: String)

/** One `get_short_epg` listing. Times are epoch millis. */
data class XtreamListing(val title: String, val description: String?, val start: Long, val stop: Long)

data class XtreamMovie(
    val streamId: String,
    val name: String,
    val categoryId: String,
    val icon: String?,
    val rating: Double?,
    val extension: String,
    val added: Long?,
)

data class XtreamSeries(
    val seriesId: String,
    val name: String,
    val categoryId: String,
    val cover: String?,
    val backdrop: String?,
    val plot: String?,
    val genre: String?,
    val releaseDate: String?,
    val rating: Double?,
)

/** `get_vod_info`. Every field is optional: panels fill in what TMDB gave them. */
data class XtreamMovieInfo(
    val plot: String? = null,
    val genre: String? = null,
    val director: String? = null,
    val cast: String? = null,
    val durationSecs: Long? = null,
    val releaseDate: String? = null,
    val backdropUrl: String? = null,
    val ageRating: String? = null,
)

data class XtreamSeason(val number: Int, val name: String?)

data class XtreamEpisode(
    val id: String,
    val season: Int,
    val episode: Int,
    val title: String?,
    val extension: String,
    val durationSecs: Long?,
    val imageUrl: String?,
    val plot: String?,
)

data class XtreamSeriesInfo(
    val seasons: List<XtreamSeason>,
    val episodes: List<XtreamEpisode>,
    val cast: String?,
    val director: String?,
    /** The show's TMDB id, which many panels send in `info.tmdb`; used to look up intro times. */
    val tmdbId: String? = null,
)

data class XtreamStream(
    val streamId: String,
    val name: String,
    val categoryId: String?,
    val icon: String?,
    val epgChannelId: String?,
    val number: Int?,
)

/**
 * The `player_api.php` calls Lumen uses: live channels, films and series. Responses are read with Android's
 * streaming [JsonReader], so a 50k-channel `get_live_streams` never sits in memory as one tree.
 *
 * Xtream panels are loose with types (ids come as numbers or strings, fields can be
 * null or missing), so every field is read leniently.
 */
class XtreamClient(private val http: OkHttpClient) {

    /** Checks the login. Throws [ImportException] with a user-facing reason if it's refused. */
    fun account(login: XtreamLogin, host: String): XtreamAccount = get(login, null, host) { reader ->
        var auth: String? = null
        var status: String? = null
        val formats = ArrayList<String>()
        // Wrong logins often get `[]` or `{"user_info":{"auth":0}}` rather than an HTTP error.
        if (reader.peek() != JsonToken.BEGIN_OBJECT) throw ImportException("$host didn't accept that username and password.")
        reader.beginObject()
        while (reader.hasNext()) {
            if (reader.nextName() != "user_info" || reader.peek() != JsonToken.BEGIN_OBJECT) {
                reader.skipValue()
                continue
            }
            reader.beginObject()
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "auth" -> auth = reader.lenientString()
                    "status" -> status = reader.lenientString()
                    "allowed_output_formats" -> if (reader.peek() == JsonToken.BEGIN_ARRAY) {
                        reader.beginArray()
                        while (reader.hasNext()) reader.lenientString()?.let { formats += it.lowercase() }
                        reader.endArray()
                    } else reader.skipValue()
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
        }
        reader.endObject()

        if (auth != "1" && auth != "true") throw ImportException("$host didn't accept that username and password.")
        when (status?.lowercase()) {
            null, "active" -> Unit
            "expired" -> throw ImportException("This subscription on $host has expired.")
            else -> throw ImportException("$host says this account is ${status.lowercase()}.")
        }
        // HLS starts faster and survives flaky Wi-Fi better; fall back to MPEG-TS.
        XtreamAccount(outputExtension = if (formats.isEmpty() || "m3u8" in formats) "m3u8" else formats.first())
    }

    fun liveCategories(login: XtreamLogin, host: String) = categories(login, "get_live_categories", host)

    /**
     * Opens `get_live_streams`. Iterate [ArrayStream.entries] (lazily, so the caller can
     * suspend between rows) and close it when done.
     */
    fun openLiveStreams(login: XtreamLogin, host: String): ArrayStream<XtreamStream> =
        ArrayStream(open(login, "get_live_streams", host), host) { reader ->
            var id: String? = null
            var name: String? = null
            var category: String? = null
            var icon: String? = null
            var epg: String? = null
            var num: Int? = null
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "stream_id" -> id = reader.lenientString()
                    "name" -> name = reader.lenientString()
                    "category_id" -> category = reader.lenientString()
                    "stream_icon" -> icon = reader.lenientString()
                    "epg_channel_id" -> epg = reader.lenientString()
                    "num" -> num = reader.lenientString()?.toIntOrNull()
                    else -> reader.skipValue()
                }
            }
            if (id != null && !name.isNullOrBlank()) {
                XtreamStream(id, name.trim(), category, icon.nonBlank(), epg.nonBlank(), num)
            } else null
        }

    /** A JSON array of objects, read one object at a time. [read] gets the reader inside each object. */
    class ArrayStream<T : Any> internal constructor(
        private val response: Response,
        private val host: String,
        private val read: (JsonReader) -> T?,
    ) : Closeable {
        private val reader = JsonReader(response.body.charStream()).apply { isLenient = true }

        val entries: Sequence<T> = sequence {
            try {
                yieldAll(readAll())
            } catch (e: IOException) {
                throw e
            } catch (e: IllegalStateException) {
                throw unreadable(host, e)
            } catch (e: NumberFormatException) {
                throw unreadable(host, e)
            }
        }

        private fun readAll(): Sequence<T> = sequence {
            if (reader.peek() != JsonToken.BEGIN_ARRAY) {
                reader.skipValue()
                return@sequence
            }
            reader.beginArray()
            while (reader.hasNext()) {
                if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                    reader.skipValue()
                    continue
                }
                reader.beginObject()
                val item = read(reader)
                reader.endObject()
                if (item != null) yield(item)
            }
            reader.endArray()
        }

        override fun close() = response.close()
    }

    fun movieCategories(login: XtreamLogin, host: String) = categories(login, "get_vod_categories", host)

    fun seriesCategories(login: XtreamLogin, host: String) = categories(login, "get_series_categories", host)

    /** Opens `get_vod_streams`: every film, ~15 MB for 35k films, so it's streamed like the channels. */
    fun openMovies(login: XtreamLogin, host: String): ArrayStream<XtreamMovie> =
        ArrayStream(open(login, "get_vod_streams", host), host) { reader ->
            var id: String? = null
            var name: String? = null
            var category: String? = null
            var icon: String? = null
            var rating: Double? = null
            var extension: String? = null
            var added: Long? = null
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "stream_id" -> id = reader.lenientString()
                    "name" -> name = reader.lenientString()
                    "category_id" -> category = reader.lenientString()
                    "stream_icon" -> icon = reader.lenientString()
                    "rating" -> rating = reader.lenientString()?.toDoubleOrNull()
                    "container_extension" -> extension = reader.lenientString()
                    "added" -> added = reader.lenientString()?.toLongOrNull()
                    else -> reader.skipValue()
                }
            }
            if (id != null && !name.isNullOrBlank()) {
                XtreamMovie(
                    id, name.trim(), category.orEmpty(), icon.nonBlank(), rating?.takeIf { it > 0 },
                    extension.nonBlank() ?: "mp4", added,
                )
            } else null
        }

    /** Opens `get_series`. Each series comes with its plot and backdrop, so the tab's hero needs no extra calls. */
    fun openSeries(login: XtreamLogin, host: String): ArrayStream<XtreamSeries> =
        ArrayStream(open(login, "get_series", host), host) { reader ->
            var id: String? = null
            var name: String? = null
            var category: String? = null
            var cover: String? = null
            var backdrop: String? = null
            var plot: String? = null
            var genre: String? = null
            var released: String? = null
            var rating: Double? = null
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "series_id" -> id = reader.lenientString()
                    "name" -> name = reader.lenientString()
                    "category_id" -> category = reader.lenientString()
                    "cover" -> cover = reader.lenientString()
                    "backdrop_path" -> backdrop = reader.firstString()
                    "plot" -> plot = reader.lenientString()
                    "genre" -> genre = reader.lenientString()
                    "releaseDate", "release_date" -> released = reader.lenientString().nonBlank() ?: released
                    "rating" -> rating = reader.lenientString()?.toDoubleOrNull()
                    else -> reader.skipValue()
                }
            }
            if (id != null && !name.isNullOrBlank()) {
                XtreamSeries(
                    id, name.trim(), category.orEmpty(), cover.nonBlank(), backdrop.nonBlank(), plot.nonBlank()?.trim(),
                    genre.nonBlank(), released, rating?.takeIf { it > 0 },
                )
            } else null
        }

    /** One film's details (`get_vod_info`): plot, cast, length and backdrop. */
    fun movieInfo(login: XtreamLogin, streamId: String, host: String): XtreamMovieInfo =
        get(login, "get_vod_info", host, extra = "vod_id" to streamId) { reader ->
            var info = XtreamMovieInfo()
            if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                reader.skipValue()
                return@get info
            }
            reader.beginObject()
            while (reader.hasNext()) {
                if (reader.nextName() != "info" || reader.peek() != JsonToken.BEGIN_OBJECT) {
                    reader.skipValue()
                    continue
                }
                reader.beginObject()
                while (reader.hasNext()) {
                    // Read each value before deciding whether to keep it: the reader must always move on.
                    when (reader.nextName()) {
                        "plot", "description" -> reader.lenientString().nonBlank()?.trim().let { info = info.copy(plot = info.plot ?: it) }
                        "genre" -> info = info.copy(genre = reader.lenientString().nonBlank())
                        "director" -> info = info.copy(director = reader.lenientString().nonBlank())
                        "cast", "actors" -> reader.lenientString().nonBlank().let { info = info.copy(cast = info.cast ?: it) }
                        "duration_secs" -> reader.lenientString()?.toLongOrNull()?.takeIf { it > 0 }?.let { info = info.copy(durationSecs = it) }
                        "releasedate" -> info = info.copy(releaseDate = reader.lenientString().nonBlank())
                        "backdrop_path" -> info = info.copy(backdropUrl = reader.firstString().nonBlank())
                        "age" -> info = info.copy(ageRating = reader.lenientString().nonBlank())
                        else -> reader.skipValue()
                    }
                }
                reader.endObject()
            }
            reader.endObject()
            info
        }

    /** A series' seasons and episodes (`get_series_info`). */
    fun seriesInfo(login: XtreamLogin, seriesId: String, host: String): XtreamSeriesInfo =
        get(login, "get_series_info", host, extra = "series_id" to seriesId) { reader ->
            val seasons = ArrayList<XtreamSeason>()
            val episodes = ArrayList<XtreamEpisode>()
            var cast: String? = null
            var director: String? = null
            var tmdb: String? = null
            if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                reader.skipValue()
                return@get XtreamSeriesInfo(emptyList(), emptyList(), null, null)
            }
            reader.beginObject()
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "seasons" -> reader.forEachObjectInArray {
                        var number: Int? = null
                        var name: String? = null
                        while (reader.hasNext()) {
                            when (reader.nextName()) {
                                "season_number" -> number = reader.lenientString()?.toIntOrNull()
                                "name" -> name = reader.lenientString()
                                else -> reader.skipValue()
                            }
                        }
                        if (number != null) seasons += XtreamSeason(number, name.nonBlank())
                    }
                    "info" -> if (reader.peek() == JsonToken.BEGIN_OBJECT) {
                        reader.beginObject()
                        while (reader.hasNext()) {
                            when (reader.nextName()) {
                                "cast" -> cast = reader.lenientString().nonBlank()
                                "director" -> director = reader.lenientString().nonBlank()
                                "tmdb", "tmdb_id" -> tmdb = reader.lenientString()?.trim()?.takeIf { it.isNotEmpty() && it.all(Char::isDigit) && it != "0" } ?: tmdb
                                else -> reader.skipValue()
                            }
                        }
                        reader.endObject()
                    } else reader.skipValue()
                    // Usually {"1": [...], "2": [...]}; a few panels send [[...], [...]].
                    "episodes" -> when (reader.peek()) {
                        JsonToken.BEGIN_OBJECT -> {
                            reader.beginObject()
                            while (reader.hasNext()) {
                                val season = reader.nextName().toIntOrNull()
                                reader.forEachObjectInArray { readEpisode(reader, season)?.let { episodes += it } }
                            }
                            reader.endObject()
                        }
                        JsonToken.BEGIN_ARRAY -> {
                            reader.beginArray()
                            while (reader.hasNext()) reader.forEachObjectInArray { readEpisode(reader, null)?.let { episodes += it } }
                            reader.endArray()
                        }
                        else -> reader.skipValue()
                    }
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
            XtreamSeriesInfo(
                seasons = seasons,
                episodes = episodes.sortedWith(compareBy({ it.season }, { it.episode })),
                cast = cast,
                director = director,
                tmdbId = tmdb,
            )
        }

    private fun readEpisode(reader: JsonReader, seasonKey: Int?): XtreamEpisode? {
        var id: String? = null
        var number: Int? = null
        var season: Int? = seasonKey
        var title: String? = null
        var extension: String? = null
        var duration: Long? = null
        var image: String? = null
        var plot: String? = null
        while (reader.hasNext()) {
            when (reader.nextName()) {
                "id" -> id = reader.lenientString()
                "episode_num" -> number = reader.lenientString()?.toIntOrNull()
                "season" -> season = reader.lenientString()?.toIntOrNull() ?: season
                "title" -> title = reader.lenientString()
                "container_extension" -> extension = reader.lenientString()
                "info" -> if (reader.peek() == JsonToken.BEGIN_OBJECT) {
                    reader.beginObject()
                    while (reader.hasNext()) {
                        when (reader.nextName()) {
                            "duration_secs" -> duration = reader.lenientString()?.toLongOrNull()
                            "movie_image" -> image = reader.lenientString()
                            "plot" -> plot = reader.lenientString()
                            else -> reader.skipValue()
                        }
                    }
                    reader.endObject()
                } else reader.skipValue()
                else -> reader.skipValue()
            }
        }
        if (id == null) return null
        return XtreamEpisode(
            id = id,
            season = season ?: 1,
            episode = number ?: 0,
            title = title.nonBlank()?.trim(),
            extension = extension.nonBlank() ?: "mp4",
            durationSecs = duration?.takeIf { it > 0 },
            imageUrl = image.nonBlank(),
            plot = plot.nonBlank()?.trim(),
        )
    }

    private fun categories(login: XtreamLogin, action: String, host: String): List<XtreamCategory> =
        get(login, action, host) { reader ->
            val out = ArrayList<XtreamCategory>()
            reader.forEachObjectInArray {
                var id: String? = null
                var name: String? = null
                while (reader.hasNext()) {
                    when (reader.nextName()) {
                        "category_id" -> id = reader.lenientString()
                        "category_name" -> name = reader.lenientString()
                        else -> reader.skipValue()
                    }
                }
                if (id != null) out += XtreamCategory(id, name?.trim().orEmpty().ifEmpty { id })
            }
            out
        }

    /**
     * The next few programmes on one channel (`get_short_epg`). A fallback for panels whose
     * `xmltv.php` is blocked or empty; one request per channel, so only for a handful at a time.
     */
    fun shortEpg(login: XtreamLogin, streamId: String, host: String, limit: Int = 4): List<XtreamListing> {
        val url = login.apiUrl("get_short_epg").newBuilder()
            .addQueryParameter("stream_id", streamId)
            .addQueryParameter("limit", limit.toString())
            .build()
        return http.newCall(Request.Builder().url(url).build()).execute().use { response ->
            if (!response.isSuccessful) throw ImportException("$host answered with error ${response.code}.")
            try {
                JsonReader(response.body.charStream()).apply { isLenient = true }.use(::readListings)
            } catch (e: IllegalStateException) {
                throw unreadable(host, e)
            } catch (e: NumberFormatException) {
                throw unreadable(host, e)
            }
        }
    }

    private fun readListings(reader: JsonReader): List<XtreamListing> {
        val out = ArrayList<XtreamListing>()
        if (reader.peek() != JsonToken.BEGIN_OBJECT) {
            reader.skipValue()
            return out
        }
        reader.beginObject()
        while (reader.hasNext()) {
            if (reader.nextName() != "epg_listings") {
                reader.skipValue()
                continue
            }
            reader.forEachObjectInArray {
                var title: String? = null
                var description: String? = null
                var start: Long? = null
                var stop: Long? = null
                while (reader.hasNext()) {
                    when (reader.nextName()) {
                        "title" -> title = reader.lenientString()
                        "description" -> description = reader.lenientString()
                        "start_timestamp" -> start = reader.lenientString()?.toLongOrNull()
                        "stop_timestamp" -> stop = reader.lenientString()?.toLongOrNull()
                        else -> reader.skipValue()
                    }
                }
                val name = title?.let(::decodeText)?.trim()
                if (!name.isNullOrEmpty() && start != null && stop != null && stop > start) {
                    out += XtreamListing(name, description?.let(::decodeText)?.trim()?.ifEmpty { null }, start * 1000, stop * 1000)
                }
            }
        }
        reader.endObject()
        return out
    }

    private fun open(login: XtreamLogin, action: String?, host: String, extra: Pair<String, String>? = null): Response {
        val url = login.apiUrl(action).let { u ->
            if (extra == null) u else u.newBuilder().addQueryParameter(extra.first, extra.second).build()
        }
        val request = Request.Builder().url(url).build()
        val response = http.newCall(request).execute()
        if (!response.isSuccessful) {
            response.close()
            throw ImportException("$host answered with error ${response.code}. Check the server and your login.")
        }
        return response
    }

    private fun <T> get(
        login: XtreamLogin,
        action: String?,
        host: String,
        extra: Pair<String, String>? = null,
        read: (JsonReader) -> T,
    ): T =
        open(login, action, host, extra).use { response ->
            try {
                JsonReader(response.body.charStream()).apply { isLenient = true }.use(read)
            } catch (e: IllegalStateException) {
                throw unreadable(host, e)
            } catch (e: NumberFormatException) {
                throw unreadable(host, e)
            }
            // IOException (network drop mid-download) passes through: the caller reports "couldn't reach".
        }

    private companion object {
        /** Xtream sends EPG text base64-encoded; a few panels send it plain. */
        fun decodeText(raw: String): String {
            val bytes = runCatching { java.util.Base64.getDecoder().decode(raw.trim()) }.getOrNull() ?: return raw
            val decoder = Charsets.UTF_8.newDecoder()
            return runCatching { decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString() }.getOrNull() ?: raw
        }

        /** The server sent something that isn't Xtream JSON (an HTML error page, say). */
        fun unreadable(host: String, cause: Throwable) =
            ImportException("$host sent something Lumen couldn't read. Is this an Xtream server?", cause)

        fun String?.nonBlank(): String? = this?.takeIf { it.isNotBlank() }

        /** The first string of an array (`backdrop_path` is a list of URLs), or a plain string. */
        fun JsonReader.firstString(): String? {
            if (peek() != JsonToken.BEGIN_ARRAY) return lenientString()
            beginArray()
            var first: String? = null
            while (hasNext()) {
                val v = lenientString()
                if (first == null && !v.isNullOrBlank()) first = v
            }
            endArray()
            return first
        }

        fun JsonReader.lenientString(): String? = when (peek()) {
            JsonToken.STRING, JsonToken.NUMBER -> nextString()
            JsonToken.BOOLEAN -> nextBoolean().toString()
            JsonToken.NULL -> { nextNull(); null }
            else -> { skipValue(); null }
        }

        /** Some panels answer an empty list as `{}` or `null`, so anything but an array means "none". */
        inline fun JsonReader.forEachObjectInArray(body: () -> Unit) {
            if (peek() != JsonToken.BEGIN_ARRAY) {
                skipValue()
                return
            }
            beginArray()
            while (hasNext()) {
                if (peek() != JsonToken.BEGIN_OBJECT) {
                    skipValue()
                    continue
                }
                beginObject()
                body()
                endObject()
            }
            endArray()
        }
    }
}
