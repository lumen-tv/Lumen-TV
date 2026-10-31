package com.hayat.lumen.data.vod

import androidx.room.withTransaction
import com.hayat.lumen.data.ImportException
import com.hayat.lumen.data.db.HiddenVodCategoryEntity
import com.hayat.lumen.data.db.LumenDatabase
import com.hayat.lumen.data.db.MovieEntity
import com.hayat.lumen.data.db.MyListEntity
import com.hayat.lumen.data.db.Poster
import com.hayat.lumen.data.db.SeriesEntity
import com.hayat.lumen.data.db.SourceEntity
import com.hayat.lumen.data.db.SourceType
import com.hayat.lumen.data.db.VodCategoryEntity
import com.hayat.lumen.data.db.VodCategoryRow
import com.hayat.lumen.data.db.VodCategorySetting
import com.hayat.lumen.data.db.RenamedVodCategoryEntity
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.db.WatchProgressEntity
import com.hayat.lumen.data.xtream.XtreamCategory
import com.hayat.lumen.data.xtream.XtreamClient
import com.hayat.lumen.data.xtream.XtreamEpisode
import com.hayat.lumen.data.xtream.XtreamLogin
import com.hayat.lumen.data.xtream.XtreamMovieInfo
import com.hayat.lumen.data.xtream.XtreamSeriesInfo
import com.hayat.lumen.util.UrlRedaction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.IOException
import kotlin.coroutines.coroutineContext

/** Background loading of the movie and series lists, for the tabs' status line. */
sealed interface VodSync {
    data object Idle : VodSync
    data class Running(val movies: Int, val series: Int) : VodSync
    data class Failed(val message: String) : VodSync
}

/** What to play: the URL plus what the player saves progress under. */
data class VodPlayable(
    val sourceId: Long,
    val kind: VodKind,
    val itemId: String,
    val url: String,
    val title: String,
    val seriesId: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
)

/**
 * Films and series from Xtream sources. The lists (tens of thousands of titles) are stored
 * in Room under a `vodGeneration`, imported like channels: streamed, batched, swapped in one
 * transaction. Details (plot, cast, episodes) are fetched when needed and cached in memory.
 */
class VodRepository(
    private val db: LumenDatabase,
    http: OkHttpClient,
    private val scope: CoroutineScope,
) {
    private val xtream = XtreamClient(http)
    private val dao = db.vod()
    private val user = db.vodUser()
    private val refreshLock = Mutex()

    private val _sync = MutableStateFlow<VodSync>(VodSync.Idle)
    val sync: StateFlow<VodSync> = _sync

    fun categories(kind: VodKind): Flow<List<VodCategoryRow>> = dao.observeCategories(kind)
    fun hiddenCount(kind: VodKind): Flow<Int> = dao.observeHiddenCount(kind)

    fun continueWatching(kind: VodKind): Flow<List<Poster>> =
        if (kind == VodKind.MOVIE) dao.observeContinueMovies() else dao.observeContinueSeries()

    /** Films and series together, for the My List tab. */
    fun myListAll(): Flow<List<Poster>> = dao.observeMyListAll()

    suspend fun postersIn(row: VodCategoryRow, limit: Int = Int.MAX_VALUE): List<Poster> =
        if (row.kind == VodKind.MOVIE) dao.moviesIn(row.sourceId, row.generation, row.categoryId, limit)
        else dao.seriesIn(row.sourceId, row.generation, row.categoryId, limit)

    /** Titles containing every word of [query], films and series separately. */
    suspend fun search(query: String): Pair<List<Poster>, List<Poster>> {
        val words = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return emptyList<Poster>() to emptyList()
        // "%dark%knight%": the words in order, anything between. % and _ in the query are escaped.
        val pattern = words.joinToString("%", prefix = "%", postfix = "%") { w ->
            w.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        }
        return dao.searchMovies(pattern, SEARCH_LIMIT) to dao.searchSeries(pattern, SEARCH_LIMIT)
    }

    suspend fun movie(sourceId: Long, streamId: String): MovieEntity? = dao.movie(sourceId, streamId)
    suspend fun series(sourceId: Long, seriesId: String): SeriesEntity? = dao.series(sourceId, seriesId)

    // Details, fetched on demand. Small LRU caches: focus moving along a row asks again and again.

    private val movieInfos = lru<String, XtreamMovieInfo>(200)
    private val seriesInfos = lru<String, XtreamSeriesInfo>(20)

    suspend fun movieInfo(sourceId: Long, streamId: String): XtreamMovieInfo? {
        val key = "$sourceId/$streamId"
        synchronized(movieInfos) { movieInfos[key] }?.let { return it }
        val info = withLogin(sourceId) { login, host -> xtream.movieInfo(login, streamId, host) } ?: return null
        synchronized(movieInfos) { movieInfos[key] = info }
        return info
    }

    /** Throws [ImportException] if the provider can't be reached, so the series page can say so. */
    suspend fun seriesInfo(sourceId: Long, seriesId: String): XtreamSeriesInfo {
        val key = "$sourceId/$seriesId"
        synchronized(seriesInfos) { seriesInfos[key] }?.let { return it }
        val info = try {
            withLogin(sourceId) { login, host -> xtream.seriesInfo(login, seriesId, host) }
        } catch (e: IOException) {
            throw ImportException("Couldn't load the episodes. Check your connection and try again.", e)
        } ?: throw ImportException("This series is no longer available.")
        synchronized(seriesInfos) { seriesInfos[key] = info }
        return info
    }

    suspend fun moviePlayable(sourceId: Long, streamId: String): VodPlayable? {
        val movie = dao.movie(sourceId, streamId) ?: return null
        val login = login(sourceId) ?: return null
        return VodPlayable(sourceId, VodKind.MOVIE, streamId, login.movieUrl(streamId, movie.extension), movie.name)
    }

    fun episodePlayable(login: XtreamLogin, sourceId: Long, seriesId: String, episode: XtreamEpisode) = VodPlayable(
        sourceId = sourceId,
        kind = VodKind.SERIES,
        itemId = episode.id,
        url = login.episodeUrl(episode.id, episode.extension),
        title = episode.title.orEmpty(),
        seriesId = seriesId,
        season = episode.season,
        episode = episode.episode,
    )

    suspend fun login(sourceId: Long): XtreamLogin? {
        val source = db.sources().get(sourceId) ?: return null
        return XtreamLogin.of(source.url, source.username.orEmpty(), source.password.orEmpty())
    }

    private suspend fun <T> withLogin(sourceId: Long, call: (XtreamLogin, String) -> T): T? = withContext(Dispatchers.IO) {
        val source = db.sources().get(sourceId) ?: return@withContext null
        val login = XtreamLogin.of(source.url, source.username.orEmpty(), source.password.orEmpty()) ?: return@withContext null
        call(login, UrlRedaction.hostOnly(source.url))
    }

    // Progress, My List, hidden categories.

    fun progress(sourceId: Long, kind: VodKind, itemId: String) = user.observeProgress(sourceId, kind, itemId)
    suspend fun progressNow(sourceId: Long, kind: VodKind, itemId: String) = user.progress(sourceId, kind, itemId)
    fun seriesProgress(sourceId: Long, seriesId: String) = user.observeSeriesProgress(sourceId, seriesId)

    /** Saves where playback is. Runs on the app scope so leaving the player doesn't cancel it. */
    fun saveProgress(item: VodPlayable, positionMs: Long, durationMs: Long) {
        if (durationMs <= 0 || positionMs < 0) return
        scope.launch {
            val finished = positionMs >= durationMs * FINISHED_FRACTION
            // Opening a title by mistake and backing out shouldn't put it in Continue watching.
            if (positionMs < MIN_SAVE_MS && !finished && user.progress(item.sourceId, item.kind, item.itemId) == null) return@launch
            user.saveProgress(
                WatchProgressEntity(
                    sourceId = item.sourceId,
                    kind = item.kind,
                    itemId = item.itemId,
                    seriesId = item.seriesId,
                    season = item.season,
                    episode = item.episode,
                    positionMs = positionMs,
                    durationMs = durationMs,
                    finished = finished,
                    inContinue = true,
                    updatedAt = System.currentTimeMillis(),
                ),
            )
        }
    }

    suspend fun removeFromContinue(poster: Poster) {
        if (poster.kind == VodKind.MOVIE) user.dismissMovie(poster.sourceId, poster.itemId)
        else user.dismissSeries(poster.sourceId, poster.itemId)
    }

    fun inMyList(sourceId: Long, kind: VodKind, itemId: String) = user.observeInMyList(sourceId, kind, itemId)

    /** Adds to My List, or removes if it's already there. Returns true if it's now in the list. */
    suspend fun toggleMyList(sourceId: Long, kind: VodKind, itemId: String): Boolean = db.withTransaction {
        if (user.inMyList(sourceId, kind, itemId)) {
            user.removeFromMyList(sourceId, kind, itemId)
            false
        } else {
            user.addToMyList(MyListEntity(sourceId, kind, itemId, System.currentTimeMillis()))
            true
        }
    }

    suspend fun hideCategory(row: VodCategoryRow) = user.hideCategory(HiddenVodCategoryEntity(row.sourceId, row.kind, row.categoryId))
    suspend fun showAllCategories(kind: VodKind) = user.showAllCategories(kind)

    /** Every category of [kind] with its hidden flag and name, for Settings. */
    fun categorySettings(kind: VodKind): Flow<List<VodCategorySetting>> = dao.observeCategorySettings(kind)

    suspend fun setCategoryHidden(c: VodCategorySetting, hidden: Boolean) =
        if (hidden) user.hideCategory(HiddenVodCategoryEntity(c.sourceId, c.kind, c.categoryId))
        else user.showCategory(c.sourceId, c.kind, c.categoryId)

    /** A blank [label], or the provider's own name, puts the provider's name back. */
    suspend fun renameCategory(c: VodCategorySetting, label: String) {
        val clean = label.trim()
        if (clean.isEmpty() || clean == c.providerName) db.renames().resetVodCategory(c.sourceId, c.kind, c.categoryId)
        else db.renames().renameVodCategory(RenamedVodCategoryEntity(c.sourceId, c.kind, c.categoryId, clean))
    }

    // Importing.

    /** Loads the lists of every visible Xtream source not loaded in the last day. */
    fun refreshStaleInBackground() {
        scope.launch {
            val now = System.currentTimeMillis()
            val stale = db.sources().all().filter {
                it.type == SourceType.XTREAM && !it.hidden && (it.vodRefreshed ?: 0L) < now - STALE_MS
            }
            for (source in stale) refreshCatching(source.id)
        }
    }

    /** Reloads one source in the background, e.g. after it's added or from Refresh. */
    fun refreshInBackground(sourceId: Long) {
        scope.launch { refreshCatching(sourceId) }
    }

    private suspend fun refreshCatching(sourceId: Long) {
        try {
            refresh(sourceId)
            _sync.value = VodSync.Idle
        } catch (e: ImportException) {
            _sync.value = VodSync.Failed(e.message ?: "Couldn't load films and series.")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Never let a background load crash the app: an odd server reply just shows here.
            _sync.value = VodSync.Failed("Couldn't load films and series.")
        }
    }

    suspend fun refresh(sourceId: Long) = refreshLock.withLock {
        withContext(Dispatchers.IO) {
            val source = db.sources().get(sourceId) ?: return@withContext
            if (source.type != SourceType.XTREAM) return@withContext
            import(source)
        }
    }

    private suspend fun import(source: SourceEntity) {
        val login = XtreamLogin.of(source.url, source.username.orEmpty(), source.password.orEmpty()) ?: return
        val host = UrlRedaction.hostOnly(source.url)
        val generation = source.vodGeneration + 1
        var movies = 0
        var series = 0
        _sync.value = VodSync.Running(0, 0)
        try {
            val movieCategories = xtream.movieCategories(login, host)
            val seriesCategories = xtream.seriesCategories(login, host)

            val movieCounts = HashMap<String, Int>()
            xtream.openMovies(login, host).use { stream ->
                val batch = ArrayList<MovieEntity>(BATCH)
                for (m in stream.entries) {
                    coroutineContext.ensureActive()
                    batch += MovieEntity(
                        sourceId = source.id,
                        generation = generation,
                        streamId = m.streamId,
                        name = m.name,
                        posterUrl = m.icon,
                        rating = m.rating,
                        categoryId = m.categoryId,
                        extension = m.extension,
                        added = m.added,
                        playlistOrder = movies++,
                    )
                    movieCounts.merge(m.categoryId, 1, Int::plus)
                    if (batch.size == BATCH) {
                        dao.insertMovies(batch.toList())
                        batch.clear()
                        _sync.value = VodSync.Running(movies, 0)
                    }
                }
                if (batch.isNotEmpty()) dao.insertMovies(batch.toList())
            }

            val seriesCounts = HashMap<String, Int>()
            xtream.openSeries(login, host).use { stream ->
                val batch = ArrayList<SeriesEntity>(BATCH)
                for (s in stream.entries) {
                    coroutineContext.ensureActive()
                    batch += SeriesEntity(
                        sourceId = source.id,
                        generation = generation,
                        seriesId = s.seriesId,
                        name = s.name,
                        posterUrl = s.cover,
                        backdropUrl = s.backdrop,
                        plot = s.plot,
                        genre = s.genre,
                        releaseDate = s.releaseDate,
                        rating = s.rating,
                        categoryId = s.categoryId,
                        playlistOrder = series++,
                    )
                    seriesCounts.merge(s.categoryId, 1, Int::plus)
                    if (batch.size == BATCH) {
                        dao.insertSeries(batch.toList())
                        batch.clear()
                        _sync.value = VodSync.Running(movies, series)
                    }
                }
                if (batch.isNotEmpty()) dao.insertSeries(batch.toList())
            }

            db.withTransaction {
                dao.insertCategories(
                    categoryRows(source.id, generation, VodKind.MOVIE, movieCategories, movieCounts) +
                        categoryRows(source.id, generation, VodKind.SERIES, seriesCategories, seriesCounts),
                )
                dao.deleteCategoriesExcept(source.id, keep = generation)
                dao.deleteMoviesExcept(source.id, keep = generation)
                dao.deleteSeriesExcept(source.id, keep = generation)
                dao.markRefreshed(source.id, generation, System.currentTimeMillis())
            }
        } catch (e: Throwable) {
            withContext(NonCancellable) {
                dao.deleteMoviesOf(source.id, generation)
                dao.deleteSeriesOf(source.id, generation)
            }
            if (e is IOException) throw ImportException("Couldn't reach $host to load films and series.", e)
            throw e
        }
    }

    /** The provider's categories in its order, then any ids it didn't list. Empty ones are left out. */
    private fun categoryRows(
        sourceId: Long,
        generation: Int,
        kind: VodKind,
        categories: List<XtreamCategory>,
        counts: Map<String, Int>,
    ): List<VodCategoryEntity> {
        val names = LinkedHashMap<String, String>()
        for (c in categories) names.putIfAbsent(c.id, c.name)
        for (id in counts.keys.sorted()) names.putIfAbsent(id, if (id.isEmpty()) "Other" else "Category $id")
        return names.entries.mapIndexedNotNull { i, (id, name) ->
            val count = counts[id] ?: 0
            if (count == 0) null
            else VodCategoryEntity(
                sourceId = sourceId, generation = generation, kind = kind, categoryId = id,
                name = name, playlistOrder = i, itemCount = count,
            )
        }
    }

    companion object {
        private const val BATCH = 500
        private const val SEARCH_LIMIT = 60
        private const val STALE_MS = 24 * 60 * 60 * 1000L
        private const val MIN_SAVE_MS = 30_000L
        const val FINISHED_FRACTION = 0.95

        /** Where to start: the saved position, unless it's near the start or the title was finished. */
        fun resumePosition(progress: WatchProgressEntity?): Long? =
            progress?.takeIf { !it.finished && it.positionMs >= MIN_SAVE_MS }?.positionMs

        private fun <K, V> lru(max: Int) = object : LinkedHashMap<K, V>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?) = size > max
        }
    }
}
