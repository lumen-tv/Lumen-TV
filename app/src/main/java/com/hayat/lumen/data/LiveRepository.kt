package com.hayat.lumen.data

import androidx.room.withTransaction
import com.hayat.lumen.data.db.ChannelEntity
import com.hayat.lumen.data.db.CategoryRow
import com.hayat.lumen.data.db.ChannelGroupEntity
import com.hayat.lumen.data.db.FavouriteRow
import com.hayat.lumen.data.db.GroupRow
import com.hayat.lumen.data.db.HiddenGroupEntity
import com.hayat.lumen.data.db.RenamedGroupEntity
import com.hayat.lumen.data.db.LumenDatabase
import com.hayat.lumen.data.db.SourceEntity
import com.hayat.lumen.data.db.SourceType
import com.hayat.lumen.data.m3u.EntryKind
import com.hayat.lumen.data.m3u.M3uEntry
import com.hayat.lumen.data.m3u.M3uParser
import com.hayat.lumen.data.m3u.StableKeys
import com.hayat.lumen.data.xtream.XtreamClient
import com.hayat.lumen.data.xtream.XtreamLogin
import com.hayat.lumen.util.UrlRedaction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import kotlin.coroutines.coroutineContext

data class ImportResult(val liveChannels: Int, val groups: Int, val skippedVod: Int, val skippedMalformed: Int)

/** User-facing failure. [message] never contains the URL (it may hold credentials). */
class ImportException(message: String, cause: Throwable? = null) : Exception(message, cause)

class LiveRepository(
    private val db: LumenDatabase,
    private val http: OkHttpClient,
) {
    private val xtream = XtreamClient(http)
    private val sourceDao = db.sources()
    private val channelDao = db.channels()
    private val favouriteDao = db.favourites()
    private val hiddenDao = db.hidden()

    val sources: Flow<List<SourceEntity>> = sourceDao.observeAll()
    val groups: Flow<List<GroupRow>> = channelDao.observeGroups()
    val favourites: Flow<List<FavouriteRow>> = favouriteDao.observe()

    /** All categories with their hidden flag, for Manage categories. */
    val categories: Flow<List<CategoryRow>> = channelDao.observeCategories()

    fun channels(sourceId: Long, groupName: String) = channelDao.observeChannels(sourceId, groupName)

    suspend fun hasSources(): Boolean = sourceDao.count() > 0

    suspend fun channel(id: Long) = channelDao.get(id)

    suspend fun playableInGroup(sourceId: Long, groupName: String) = channelDao.playableInGroup(sourceId, groupName)

    suspend fun playableFavourites() = favouriteDao.playable()

    /** Adds the channel to favourites, or removes it if it already is one. */
    suspend fun toggleFavourite(channelId: Long) = db.withTransaction {
        val channel = channelDao.get(channelId) ?: return@withTransaction
        if (favouriteDao.contains(channel.sourceId, channel.stableKey)) {
            favouriteDao.remove(channel.sourceId, channel.stableKey)
        } else {
            favouriteDao.add(channel.sourceId, channel.stableKey, System.currentTimeMillis())
        }
    }

    suspend fun removeFavourite(sourceId: Long, stableKey: String) = favouriteDao.remove(sourceId, stableKey)

    /**
     * Saves the Home order after the user moved a favourite. Only the favourites on show are
     * renumbered; hidden ones (hidden playlist, or gone from the playlist) keep their old
     * number, so they come back roughly where they were.
     */
    suspend fun reorderFavourites(order: List<FavouriteRow>) = db.withTransaction {
        order.forEachIndexed { index, f -> favouriteDao.setPosition(f.sourceId, f.stableKey, index) }
    }

    // Hiding. Chunked because SQLite on older Android allows at most 999 query parameters.

    suspend fun hideGroups(sourceId: Long, names: List<String>) = db.withTransaction {
        for (chunk in names.chunked(CHUNK)) hiddenDao.hide(chunk.map { HiddenGroupEntity(sourceId, it) })
    }

    suspend fun showGroups(sourceId: Long, names: List<String>) = db.withTransaction {
        for (chunk in names.chunked(CHUNK)) hiddenDao.show(sourceId, chunk)
    }

    suspend fun setSourceHidden(sourceId: Long, hidden: Boolean) = sourceDao.setHidden(sourceId, hidden)

    // Renaming. Display only: the provider's names stay the keys (for hiding, the player's group, the guide).

    /** A blank [label], or the provider's own name, puts the provider's name back. */
    suspend fun renameGroup(sourceId: Long, groupName: String, label: String) {
        val clean = label.trim()
        if (clean.isEmpty() || clean == groupName) db.renames().resetGroup(sourceId, groupName)
        else db.renames().renameGroup(RenamedGroupEntity(sourceId, groupName, clean))
    }

    suspend fun renameSource(sourceId: Long, name: String) {
        name.trim().takeIf { it.isNotEmpty() }?.let { sourceDao.rename(sourceId, it) }
    }

    /**
     * Points a playlist at a new link ([url]) or Xtream login, then refreshes it. If that import
     * fails, the old link comes back, so a typo never breaks a working playlist. A blank
     * [password] keeps the current one. Favourites, hidden and renamed categories are kept.
     */
    suspend fun changeConnection(
        sourceId: Long,
        url: String? = null,
        login: XtreamLogin? = null,
        onProgress: (Int) -> Unit,
    ): ImportResult {
        val old = sourceDao.get(sourceId) ?: throw ImportException("This playlist no longer exists.")
        val xtreamLogin = login ?: url?.let(XtreamLogin::fromPlaylistUrl)
        if (xtreamLogin != null) {
            sourceDao.setConnection(sourceId, SourceType.XTREAM, xtreamLogin.server.toString(), xtreamLogin.username, xtreamLogin.password)
        } else {
            val link = url?.trim()?.takeIf { it.isNotEmpty() } ?: throw ImportException("Paste a playlist link first.")
            sourceDao.setConnection(sourceId, SourceType.M3U, link, null, null)
        }
        return try {
            refresh(sourceId, onProgress)
        } catch (e: Throwable) {
            withContext(NonCancellable) { sourceDao.setConnection(sourceId, old.type, old.url, old.username, old.password) }
            throw e
        }
    }

    /**
     * Adds an M3U source and imports it. If the first import fails, the source is removed again.
     * Xtream `get.php` links are stored as an Xtream login instead: many providers block that
     * download but keep the API, and the API has proper groups.
     */
    suspend fun addM3u(name: String, url: String, onProgress: (Int) -> Unit): ImportResult {
        XtreamLogin.fromPlaylistUrl(url)?.let { return addXtream(name, it, onProgress) }
        return addAndImport(SourceEntity(type = SourceType.M3U, name = name.trim(), url = url.trim()), onProgress)
    }

    suspend fun addXtream(name: String, login: XtreamLogin, onProgress: (Int) -> Unit): ImportResult =
        addAndImport(
            SourceEntity(
                type = SourceType.XTREAM,
                name = name.trim(),
                url = login.server.toString(),
                username = login.username,
                password = login.password,
            ),
            onProgress,
        )

    private suspend fun addAndImport(source: SourceEntity, onProgress: (Int) -> Unit): ImportResult {
        val id = sourceDao.insert(source)
        return try {
            refresh(id, onProgress)
        } catch (e: Throwable) {
            remove(id)
            throw e
        }
    }

    suspend fun remove(sourceId: Long) = db.withTransaction {
        channelDao.deleteAllChannels(sourceId)
        channelDao.deleteAllGroups(sourceId)
        db.epg().deleteAllProgrammes(sourceId)
        db.epg().deleteState(sourceId)
        favouriteDao.removeAllOf(sourceId)
        hiddenDao.removeAllOf(sourceId)
        db.renames().removeGroupsOf(sourceId)
        db.renames().removeVodCategoriesOf(sourceId)
        db.vod().run {
            deleteAllCategories(sourceId)
            deleteAllMovies(sourceId)
            deleteAllSeries(sourceId)
            deleteAllProgress(sourceId)
            deleteMyList(sourceId)
            deleteHiddenCategories(sourceId)
        }
        sourceDao.delete(sourceId)
    }

    /**
     * Downloads and stream-parses the source, writing channels in batches under a new
     * generation, then swaps generations in one transaction. On failure the old data stays.
     */
    suspend fun refresh(sourceId: Long, onProgress: (Int) -> Unit = {}): ImportResult = withContext(Dispatchers.IO) {
        val source = sourceDao.get(sourceId) ?: throw ImportException("This playlist no longer exists.")
        val host = UrlRedaction.hostOnly(source.url)
        val generation = source.generation + 1

        try {
            val result = when (source.type) {
                SourceType.M3U -> importM3u(source, host, generation, onProgress)
                SourceType.XTREAM -> importXtream(source, host, generation, onProgress)
            }
            if (result.liveChannels == 0) {
                throw ImportException(
                    if (result.skippedVod > 0) "This playlist only has films and series. Live TV only for now."
                    else if (source.type == SourceType.XTREAM) "No live channels found on this account."
                    else "No channels found. Is this an M3U playlist?",
                )
            }
            result
        } catch (e: IOException) {
            discard(source.id, generation)
            throw ImportException("Couldn't reach $host. Check your connection and try again.", e)
        } catch (e: Throwable) {
            discard(source.id, generation) // also on cancellation, hence NonCancellable inside
            throw e
        }
    }

    private suspend fun importM3u(source: SourceEntity, host: String, generation: Int, onProgress: (Int) -> Unit): ImportResult {
        val request = runCatching { Request.Builder().url(source.url).build() }
            .getOrElse { throw ImportException("That doesn't look like a valid web address.") }
        return http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw ImportException("$host answered with error ${response.code}. Check the URL and your login.")
            }
            val parser = M3uParser()
            val counts = importEntries(source.id, generation, parser.entries(response.body.charStream().buffered().lineSequence()), emptyList(), onProgress) {
                parser.header.epgUrl?.let { sourceDao.setEpgUrlIfMissing(source.id, it) }
            }
            counts.copy(skippedMalformed = parser.skipped)
        }
    }

    private suspend fun importXtream(source: SourceEntity, host: String, generation: Int, onProgress: (Int) -> Unit): ImportResult {
        val login = XtreamLogin.of(source.url, source.username.orEmpty(), source.password.orEmpty())
            ?: throw ImportException("Enter a server address, username and password.")
        val account = xtream.account(login, host)
        val categories = xtream.liveCategories(login, host)
        val groupNames = categories.associate { it.id to it.name }
        return xtream.openLiveStreams(login, host).use { streams ->
            val entries = streams.entries.map { s ->
                M3uEntry(
                    name = s.name,
                    url = login.liveStreamUrl(s.streamId, account.outputExtension),
                    kind = EntryKind.LIVE,
                    tvgId = s.epgChannelId,
                    tvgName = null,
                    tvgLogo = s.icon,
                    groupTitle = s.categoryId?.let(groupNames::get),
                    tvgChno = s.number,
                )
            }
            importEntries(source.id, generation, entries, categories.map { it.name }, onProgress) {}
        }
    }

    private suspend fun discard(sourceId: Long, generation: Int) = withContext(NonCancellable) {
        channelDao.deleteChannelsOf(sourceId, generation)
    }

    /**
     * Writes [entries] under [generation] and, if any were live, swaps them in.
     * [groupOrder] fixes the order of known groups (Xtream categories); others follow in
     * first-seen order. [inSwap] runs inside the swap transaction.
     */
    private suspend fun importEntries(
        sourceId: Long,
        generation: Int,
        entries: Sequence<M3uEntry>,
        groupOrder: List<String>,
        onProgress: (Int) -> Unit,
        inSwap: suspend () -> Unit,
    ): ImportResult {
        val keys = StableKeys()
        val batch = ArrayList<ChannelEntity>(BATCH)
        // Group name -> [first-seen order, channel count]. Hundreds of entries at most.
        val groups = LinkedHashMap<String, IntArray>()
        for (name in groupOrder) groups.getOrPut(name) { intArrayOf(groups.size, 0) }
        var live = 0
        var vod = 0

        for (entry in entries) {
            if (entry.kind != EntryKind.LIVE) {
                vod++
                continue
            }
            coroutineContext.ensureActive() // stop promptly if the user backs out
            val group = entry.groupTitle ?: UNGROUPED
            val g = groups.getOrPut(group) { intArrayOf(groups.size, 0) }
            g[1]++
            batch += ChannelEntity(
                sourceId = sourceId,
                generation = generation,
                stableKey = keys.keyFor(entry),
                name = entry.name,
                streamUrl = entry.url,
                logoUrl = entry.tvgLogo,
                groupName = group,
                tvgId = entry.tvgId,
                number = entry.tvgChno,
                playlistOrder = live,
            )
            live++
            if (batch.size == BATCH) {
                channelDao.insertChannels(batch.toList())
                batch.clear()
                onProgress(live)
            }
        }
        if (batch.isNotEmpty()) channelDao.insertChannels(batch.toList())
        onProgress(live)

        if (live > 0) {
            db.withTransaction {
                channelDao.insertGroups(
                    groups.filterValues { it[1] > 0 }.map { (name, v) ->
                        ChannelGroupEntity(sourceId = sourceId, generation = generation, name = name, playlistOrder = v[0], channelCount = v[1])
                    },
                )
                channelDao.deleteChannelsExcept(sourceId, keep = generation)
                channelDao.deleteGroupsExcept(sourceId, keep = generation)
                sourceDao.markRefreshed(sourceId, generation, System.currentTimeMillis())
                inSwap()
            }
        }
        return ImportResult(live, groups.count { it.value[1] > 0 }, vod, skippedMalformed = 0)
    }

    private companion object {
        const val BATCH = 500
        const val CHUNK = 500
        const val UNGROUPED = "All channels"
    }
}
