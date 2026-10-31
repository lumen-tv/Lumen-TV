package com.hayat.lumen.core

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsBytes
import kotlinx.io.Buffer
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.DecodeSequenceMode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.io.decodeSourceToSequence

internal class XtreamAccount(val outputExtension: String)
internal class XtreamCategory(val id: String, val name: String)
internal class XtreamStream(
    val streamId: String,
    val name: String,
    val categoryId: String?,
    val icon: String?,
    val epgChannelId: String?,
    val number: Int?,
)

/**
 * The `player_api.php` calls the iPhone app uses (live channels for now). Xtream panels are
 * loose with types (ids come as numbers or strings, fields can be null or missing), so every
 * field is read as raw JSON and converted leniently.
 */
internal class XtreamApi(private val http: HttpClient) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** Checks the login. Throws [LoadException] with a user-facing reason if it's refused. */
    suspend fun account(server: XtreamServer): XtreamAccount {
        val root = json.parseToJsonElement(fetch(server, null).decodeToString())
        val refused = LoadException("${server.host} didn't accept that username and password.")
        // Wrong logins often get `[]` or `{"user_info":{"auth":0}}` rather than an HTTP error.
        val user = ((root as? JsonObject)?.get("user_info") as? JsonObject) ?: throw refused
        val auth = user["auth"].lenient()
        if (auth != "1" && auth != "true") throw refused
        val status = user["status"].lenient()?.lowercase()
        when (status) {
            null, "active" -> Unit
            "expired" -> throw LoadException("This subscription on ${server.host} has expired.")
            else -> throw LoadException("${server.host} says this account is $status.")
        }
        val formats = (user["allowed_output_formats"] as? JsonArray).orEmpty().mapNotNull { it.lenient()?.lowercase() }
        // HLS starts faster and is what Apple's player plays best; fall back to MPEG-TS.
        return XtreamAccount(if (formats.isEmpty() || "m3u8" in formats) "m3u8" else formats.first())
    }

    suspend fun liveCategories(server: XtreamServer): List<XtreamCategory> =
        decodeArray(server, "get_live_categories", RawCategory.serializer()).mapNotNull { c ->
            val id = c.id.lenient() ?: return@mapNotNull null
            val name = c.name.lenient()?.trim()?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            XtreamCategory(id, name)
        }.toList()

    suspend fun liveStreams(server: XtreamServer): List<XtreamStream> =
        decodeArray(server, "get_live_streams", RawStream.serializer()).mapNotNull { s ->
            val id = s.streamId.lenient() ?: return@mapNotNull null
            val name = s.name.lenient()?.trim()?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            XtreamStream(
                id, name, s.categoryId.lenient(), s.icon.lenient().nonBlank(), s.epg.lenient().nonBlank(),
                s.num.lenient()?.toIntOrNull(),
            )
        }.toList()

    suspend fun categories(server: XtreamServer, action: String): List<XtreamCategory> =
        decodeArray(server, action, RawCategory.serializer()).mapNotNull { c ->
            val id = c.id.lenient() ?: return@mapNotNull null
            XtreamCategory(id, c.name.lenient()?.trim()?.takeIf { it.isNotEmpty() } ?: id)
        }.toList()

    suspend fun movies(server: XtreamServer): List<RawMovie> = decodeArray(server, "get_vod_streams", RawMovie.serializer()).toList()

    suspend fun series(server: XtreamServer): List<RawSeries> = decodeArray(server, "get_series", RawSeries.serializer()).toList()

    /** `get_vod_info`: the `info` object, or null. */
    suspend fun movieInfo(server: XtreamServer, movieId: String): JsonObject? =
        (parse(server, "get_vod_info", mapOf("vod_id" to movieId)) as? JsonObject)?.get("info") as? JsonObject

    /** `get_series_info`: the whole answer (seasons, info, episodes), or null. */
    suspend fun seriesInfo(server: XtreamServer, seriesId: String): JsonObject? =
        parse(server, "get_series_info", mapOf("series_id" to seriesId)) as? JsonObject

    private suspend fun parse(server: XtreamServer, action: String, extra: Map<String, String>): JsonElement? {
        val text = fetch(server, action, extra).decodeToString()
        return try {
            json.parseToJsonElement(text)
        } catch (e: Exception) {
            throw LoadException("${server.host} sent something Lumen couldn't read.", e)
        }
    }

    /**
     * Reads a JSON array one object at a time, so a 50k-channel list never exists as one big
     * JSON tree (the download itself is held as bytes). Anything that isn't an array is empty.
     */
    @OptIn(ExperimentalSerializationApi::class)
    private suspend fun <T> decodeArray(
        server: XtreamServer,
        action: String,
        serializer: kotlinx.serialization.KSerializer<T>,
    ): Sequence<T> {
        var bytes = fetch(server, action)
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) {
            bytes = bytes.copyOfRange(3, bytes.size) // UTF-8 byte-order mark
        }
        val start = bytes.indexOfFirst { it.toInt().toChar() !in " \t\r\n" }
        if (start == -1 || bytes[start] != '['.code.toByte()) return emptySequence()
        val source = Buffer().apply { write(bytes) }
        return try {
            json.decodeSourceToSequence(source, serializer, DecodeSequenceMode.ARRAY_WRAPPED).toList().asSequence()
        } catch (e: Exception) {
            throw LoadException("${server.host} sent a list Lumen couldn't read.", e)
        }
    }

    private suspend fun fetch(server: XtreamServer, action: String?, extra: Map<String, String> = emptyMap()): ByteArray {
        val response: HttpResponse = try {
            http.get(server.apiUrl(action, extra))
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            throw LoadException("Couldn't reach ${server.host}. Check the address and your connection.", e)
        }
        if (response.status.value !in 200..299) {
            throw LoadException("${server.host} answered with error ${response.status.value}. Check the address and your login.")
        }
        return response.bodyAsBytes()
    }

    @Serializable
    private class RawCategory(
        @SerialName("category_id") val id: JsonElement? = null,
        @SerialName("category_name") val name: JsonElement? = null,
    )

    @Serializable
    class RawMovie(
        @SerialName("stream_id") val streamId: JsonElement? = null,
        val name: JsonElement? = null,
        @SerialName("category_id") val categoryId: JsonElement? = null,
        @SerialName("stream_icon") val icon: JsonElement? = null,
        val rating: JsonElement? = null,
        @SerialName("container_extension") val extension: JsonElement? = null,
        val added: JsonElement? = null,
    )

    @Serializable
    class RawSeries(
        @SerialName("series_id") val seriesId: JsonElement? = null,
        val name: JsonElement? = null,
        @SerialName("category_id") val categoryId: JsonElement? = null,
        val cover: JsonElement? = null,
        @SerialName("backdrop_path") val backdrop: JsonElement? = null,
        val plot: JsonElement? = null,
        val genre: JsonElement? = null,
        val releaseDate: JsonElement? = null,
        @SerialName("release_date") val releaseDate2: JsonElement? = null,
        val rating: JsonElement? = null,
    )

    @Serializable
    private class RawStream(
        @SerialName("stream_id") val streamId: JsonElement? = null,
        val name: JsonElement? = null,
        @SerialName("category_id") val categoryId: JsonElement? = null,
        @SerialName("stream_icon") val icon: JsonElement? = null,
        @SerialName("epg_channel_id") val epg: JsonElement? = null,
        val num: JsonElement? = null,
    )
}

/** A JSON string, number or boolean as text; null for null, objects and arrays. */
internal fun JsonElement?.lenient(): String? =
    (this as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content

/** The first string of an array (`backdrop_path` is a list of URLs), or a plain string. */
internal fun JsonElement?.firstString(): String? =
    if (this is JsonArray) firstNotNullOfOrNull { it.lenient().nonBlank() } else lenient()

internal fun String?.nonBlank(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
