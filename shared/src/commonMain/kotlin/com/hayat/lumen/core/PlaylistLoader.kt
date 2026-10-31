package com.hayat.lumen.core

import com.hayat.lumen.data.m3u.EntryKind
import com.hayat.lumen.data.m3u.M3uEntry
import com.hayat.lumen.data.m3u.M3uParser
import com.hayat.lumen.data.m3u.StableKeys
import com.hayat.lumen.util.CategoryNames
import com.hayat.lumen.util.ChannelNames
import com.hayat.lumen.util.UrlRedaction
import com.hayat.lumen.util.VodNames
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import io.ktor.client.HttpClient
import io.ktor.client.plugins.timeout
import io.ktor.client.request.get
import io.ktor.client.request.prepareGet
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.utils.io.readAvailable
import kotlinx.coroutines.CancellationException

/**
 * Loads a playlist's live channels: the entry point the iPhone app calls. Each method is a
 * Kotlin `suspend` function, which Swift sees as `async throws`.
 */
class PlaylistLoader internal constructor(private val http: HttpClient) {
    private val xtream = XtreamApi(http)

    /** An Xtream login typed in the form. */
    @Throws(Exception::class)
    suspend fun loadXtream(server: String, username: String, password: String): LiveLibrary {
        val login = XtreamServer.of(server, username, password)
            ?: throw LoadException("Enter a server address, username and password.")
        return loadXtream(login)
    }

    /** An M3U link. An Xtream `get.php` link is loaded through the Xtream API instead (see [isXtreamLink]). */
    @Throws(Exception::class)
    suspend fun loadM3u(link: String): LiveLibrary {
        XtreamServer.fromPlaylistUrl(link)?.let { return loadXtream(it) }
        val url = link.trim()
        if (!url.startsWith("http://", ignoreCase = true) && !url.startsWith("https://", ignoreCase = true)) {
            throw LoadException("That doesn't look like a web address.")
        }
        val host = UrlRedaction.hostOnly(url)
        val text = try {
            val response = http.get(url)
            if (response.status.value !in 200..299) {
                throw LoadException("$host answered with error ${response.status.value}. Check the link.")
            }
            response.bodyAsText()
        } catch (e: LoadException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw LoadException("Couldn't reach $host. Check the link and your connection.", e)
        }
        val parser = M3uParser()
        val entries = parser.entries(text.lineSequence()).filter { it.kind == EntryKind.LIVE }.toList()
        if (entries.isEmpty()) throw LoadException("No channels found in that playlist.")
        return build(entries, categoryOrder = emptyList(), epgUrl = parser.header.epgUrl, skipped = parser.skipped)
    }

    /** Films and series for an Xtream login (M3U playlists have none). */
    @Throws(Exception::class)
    suspend fun loadVod(server: String, username: String, password: String): VodLibrary {
        val login = XtreamServer.of(server, username, password)
            ?: throw LoadException("Enter a server address, username and password.")
        val movieCategories = xtream.categories(login, "get_vod_categories")
        val movies = xtream.movies(login).mapNotNull { m ->
            val id = m.streamId.lenient() ?: return@mapNotNull null
            val raw = m.name.lenient().nonBlank() ?: return@mapNotNull null
            val name = VodNames.display(raw)
            Movie(
                id = id,
                name = raw,
                title = name.title,
                year = name.year,
                quality = name.tags.firstOrNull { it == "4K" },
                categoryId = m.categoryId.lenient().orEmpty(),
                posterUrl = m.icon.lenient().nonBlank(),
                rating = m.rating.lenient()?.toDoubleOrNull()?.takeIf { it > 0 },
                streamUrl = login.movieUrl(id, m.extension.lenient().nonBlank() ?: "mp4"),
                added = m.added.lenient()?.toLongOrNull(),
            )
        }
        val seriesCategories = xtream.categories(login, "get_series_categories")
        val series = xtream.series(login).mapNotNull { s ->
            val id = s.seriesId.lenient() ?: return@mapNotNull null
            val raw = s.name.lenient().nonBlank() ?: return@mapNotNull null
            val name = VodNames.display(raw)
            val released = s.releaseDate.lenient().nonBlank() ?: s.releaseDate2.lenient().nonBlank()
            Series(
                id = id,
                name = raw,
                title = name.title,
                year = name.year ?: released?.take(4)?.toIntOrNull(),
                categoryId = s.categoryId.lenient().orEmpty(),
                posterUrl = s.cover.lenient().nonBlank(),
                backdropUrl = s.backdrop.firstString().nonBlank(),
                plot = s.plot.lenient().nonBlank(),
                genre = s.genre.lenient().nonBlank(),
                rating = s.rating.lenient()?.toDoubleOrNull()?.takeIf { it > 0 },
            )
        }
        return VodLibrary(
            vodCategories(movieCategories, movies.groupingBy { it.categoryId }.eachCount()),
            movies,
            vodCategories(seriesCategories, series.groupingBy { it.categoryId }.eachCount()),
            series,
        )
    }

    /** In the provider's order, only categories that have something in them. */
    private fun vodCategories(categories: List<XtreamCategory>, counts: Map<String, Int>): List<VodCategory> =
        categories.filter { (counts[it.id] ?: 0) > 0 }.map { c ->
            val display = CategoryNames.display(c.name)
            VodCategory(c.id, c.name, display.title, display.tags.firstOrNull { it == "4K" }, counts.getValue(c.id))
        }

    /** One film's details. */
    @Throws(Exception::class)
    suspend fun movieInfo(server: String, username: String, password: String, movieId: String): MovieInfo {
        val login = XtreamServer.of(server, username, password) ?: throw LoadException("This playlist's login is incomplete.")
        val info = xtream.movieInfo(login, movieId)
        return MovieInfo(
            plot = info?.get("plot").lenient().nonBlank() ?: info?.get("description").lenient().nonBlank(),
            genre = info?.get("genre").lenient().nonBlank(),
            director = info?.get("director").lenient().nonBlank(),
            cast = info?.get("cast").lenient().nonBlank() ?: info?.get("actors").lenient().nonBlank(),
            durationSecs = info?.get("duration_secs").lenient()?.toLongOrNull()?.takeIf { it > 0 },
            releaseDate = info?.get("releasedate").lenient().nonBlank(),
            backdropUrl = info?.get("backdrop_path").firstString().nonBlank(),
            ageRating = info?.get("age").lenient().nonBlank(),
        )
    }

    /** A series' seasons and episodes. */
    @Throws(Exception::class)
    suspend fun seriesInfo(server: String, username: String, password: String, seriesId: String): SeriesInfo {
        val login = XtreamServer.of(server, username, password) ?: throw LoadException("This playlist's login is incomplete.")
        val root = xtream.seriesInfo(login, seriesId)
        val episodes = ArrayList<Episode>()
        // "D+ - Modern Family S01E03 - Come Fly with Me" → "Come Fly with Me", as on the TV.
        val showName = ((root?.get("info") as? JsonObject)?.get("name")).lenient().nonBlank()?.let { VodNames.display(it).title }
        fun read(e: JsonObject, seasonKey: Int?) {
            val id = e["id"].lenient() ?: return
            val info = e["info"] as? JsonObject
            episodes += Episode(
                id = id,
                season = e["season"].lenient()?.toIntOrNull() ?: seasonKey ?: 1,
                episode = e["episode_num"].lenient()?.toIntOrNull() ?: 0,
                title = VodNames.episode(e["title"].lenient(), showName),
                durationSecs = info?.get("duration_secs").lenient()?.toLongOrNull()?.takeIf { it > 0 },
                imageUrl = info?.get("movie_image").lenient().nonBlank(),
                plot = info?.get("plot").lenient().nonBlank(),
                streamUrl = login.episodeUrl(id, e["container_extension"].lenient().nonBlank() ?: "mp4"),
            )
        }
        // Usually {"1": [...], "2": [...]}; a few panels send [[...], [...]].
        when (val all = root?.get("episodes")) {
            is JsonObject -> all.forEach { (season, list) ->
                (list as? JsonArray)?.forEach { (it as? JsonObject)?.let { e -> read(e, season.toIntOrNull()) } }
            }
            is JsonArray -> all.forEach { list ->
                (list as? JsonArray)?.forEach { (it as? JsonObject)?.let { e -> read(e, null) } }
            }
            else -> Unit
        }
        val sorted = episodes.sortedWith(compareBy({ it.season }, { it.episode }))
        val info = root?.get("info") as? JsonObject
        return SeriesInfo(
            seasons = sorted.map { it.season }.distinct(),
            episodes = sorted,
            cast = info?.get("cast").lenient().nonBlank(),
            director = info?.get("director").lenient().nonBlank(),
            tmdbId = (info?.get("tmdb").lenient() ?: info?.get("tmdb_id").lenient())?.trim()
                ?.takeIf { it.isNotEmpty() && it != "0" && it.all(Char::isDigit) },
        )
    }

    /**
     * The TV guide for an Xtream login, from the panel's `xmltv.php`. [tvgIds] are the playlist's
     * channels' tvg-ids; [now] is epoch seconds (programmes from now − 2 h to now + 36 h are kept).
     */
    @Throws(Exception::class)
    suspend fun loadXtreamGuide(server: String, username: String, password: String, tvgIds: List<String>, now: Long): Guide {
        val login = XtreamServer.of(server, username, password) ?: throw LoadException("This playlist's login is incomplete.")
        return loadGuide(login.xmltvUrl(), UrlRedaction.hostOnly(login.base.toString()), tvgIds, now)
    }

    /** The TV guide from an XMLTV link (an M3U's `url-tvg`, or one the user typed). */
    @Throws(Exception::class)
    suspend fun loadGuide(url: String, tvgIds: List<String>, now: Long): Guide =
        loadGuide(url.trim(), UrlRedaction.hostOnly(url.trim()), tvgIds, now)

    private suspend fun loadGuide(url: String, host: String, tvgIds: List<String>, now: Long): Guide {
        val wanted = tvgIds.mapNotNullTo(HashSet()) { id -> id.trim().lowercase().takeIf { it.isNotEmpty() } }
        if (wanted.isEmpty()) throw LoadException("These channels have no guide IDs, so there's no TV guide for them.")
        val reader = XmltvReader(wanted, from = now - 2 * 3600, to = now + 36 * 3600)
        try {
            http.prepareGet(url) {
                // A full guide can be big and slow: give it 10 minutes, not the usual 2.
                timeout { requestTimeoutMillis = 600_000 }
            }.execute { response ->
                if (response.status.value !in 200..299) {
                    throw LoadException("$host answered with error ${response.status.value} for the TV guide.")
                }
                val body = response.bodyAsChannel()
                val buffer = ByteArray(64 * 1024)
                var first = true
                while (true) {
                    val count = body.readAvailable(buffer, 0, buffer.size)
                    if (count < 0) break
                    if (count == 0) continue
                    if (first) {
                        first = false
                        // A .gz guide file (not Content-Encoding, which the networking unzips itself).
                        if (count >= 2 && buffer[0] == 0x1f.toByte() && buffer[1] == 0x8b.toByte()) {
                            throw LoadException("The TV guide from $host is a compressed .gz file, which the iPhone app can't read yet.")
                        }
                    }
                    reader.feed(buffer, count)
                }
            }
        } catch (e: LoadException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw LoadException("Couldn't load the TV guide from $host.", e)
        }
        val guide = reader.finish()
        if (reader.seen == 0) throw LoadException("$host sent a TV guide Lumen couldn't read.")
        return guide
    }

    /** True for `get.php` / `player_api.php` links, which carry an Xtream login. */
    fun isXtreamLink(link: String): Boolean = XtreamServer.fromPlaylistUrl(link) != null

    /** The login inside an Xtream link, to store it like a typed one. Null for other links. */
    fun xtreamLogin(link: String): XtreamLoginParts? =
        XtreamServer.fromPlaylistUrl(link)?.let { XtreamLoginParts(it.base.toString(), it.username, it.password) }

    private suspend fun loadXtream(login: XtreamServer): LiveLibrary {
        val account = xtream.account(login)
        val categories = xtream.liveCategories(login)
        val names = categories.associate { it.id to it.name }
        val entries = xtream.liveStreams(login).map { s ->
            M3uEntry(
                name = s.name,
                url = login.liveStreamUrl(s.streamId, account.outputExtension),
                kind = EntryKind.LIVE,
                tvgId = s.epgChannelId,
                tvgName = null,
                tvgLogo = s.icon,
                groupTitle = s.categoryId?.let(names::get),
                tvgChno = s.number,
            )
        }
        if (entries.isEmpty()) throw LoadException("${login.host} has no live channels for this login.")
        return build(entries, categories.map { it.name }, epgUrl = null, skipped = 0)
    }

    /** Same keys and grouping as the Android import (`LiveRepository.importEntries`). */
    private fun build(entries: List<M3uEntry>, categoryOrder: List<String>, epgUrl: String?, skipped: Int): LiveLibrary {
        val keys = StableKeys()
        val channels = entries.map { e ->
            val display = ChannelNames.display(e.name)
            LiveChannel(
                key = keys.keyFor(e),
                name = e.name,
                title = display.title,
                quality = display.tags.firstOrNull(),
                categoryName = e.groupTitle,
                logoUrl = e.tvgLogo,
                streamUrl = e.url,
                tvgId = e.tvgId,
                number = e.tvgChno,
            )
        }
        val counts = channels.groupingBy { it.categoryName }.eachCount()
        val order = (categoryOrder + channels.mapNotNull { it.categoryName }).distinct()
        val categories = order.filter { (counts[it] ?: 0) > 0 }.map { LiveCategory(it, CategoryNames.title(it), counts.getValue(it)) }
        return LiveLibrary(categories, channels, epgUrl, skipped)
    }
}

class XtreamLoginParts(val server: String, val username: String, val password: String)
