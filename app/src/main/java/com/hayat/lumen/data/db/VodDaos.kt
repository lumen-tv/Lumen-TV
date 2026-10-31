package com.hayat.lumen.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/**
 * Movie and series lists. Like channels, rows only ever come from a source's current
 * `vodGeneration`, and hidden playlists are left out.
 */
@Dao
interface VodDao {
    @Insert
    suspend fun insertCategories(categories: List<VodCategoryEntity>)

    @Insert
    suspend fun insertMovies(movies: List<MovieEntity>)

    @Insert
    suspend fun insertSeries(series: List<SeriesEntity>)

    /** The rows of the Movies or Series tab, in the provider's order. Hidden categories are left out. */
    @Query(
        """
        SELECT c.sourceId, c.generation, c.kind, c.categoryId, COALESCE((SELECT r.label FROM renamed_vod_categories r WHERE r.sourceId = c.sourceId AND r.kind = c.kind AND r.categoryId = c.categoryId), c.name) AS name, c.itemCount
        FROM vod_categories c JOIN sources s ON s.id = c.sourceId AND s.vodGeneration = c.generation
        WHERE s.hidden = 0 AND c.kind = :kind
            AND NOT EXISTS(
                SELECT 1 FROM hidden_vod_categories h
                WHERE h.sourceId = c.sourceId AND h.kind = c.kind AND h.categoryId = c.categoryId
            )
        ORDER BY c.sourceId, c.playlistOrder
        """,
    )
    fun observeCategories(kind: VodKind): Flow<List<VodCategoryRow>>

    /** Every category of [kind], hidden or not, for Settings. */
    @Query(
        """
        SELECT c.sourceId, c.kind, c.categoryId, c.name AS providerName, COALESCE((SELECT r.label FROM renamed_vod_categories r WHERE r.sourceId = c.sourceId AND r.kind = c.kind AND r.categoryId = c.categoryId), c.name) AS name, c.itemCount,
            EXISTS(
                SELECT 1 FROM hidden_vod_categories h
                WHERE h.sourceId = c.sourceId AND h.kind = c.kind AND h.categoryId = c.categoryId
            ) AS hidden
        FROM vod_categories c JOIN sources s ON s.id = c.sourceId AND s.vodGeneration = c.generation
        WHERE s.hidden = 0 AND c.kind = :kind
        ORDER BY c.sourceId, c.playlistOrder
        """,
    )
    fun observeCategorySettings(kind: VodKind): Flow<List<VodCategorySetting>>

    @Query(
        """
        SELECT COUNT(*) FROM hidden_vod_categories h JOIN sources s ON s.id = h.sourceId
        WHERE s.hidden = 0 AND h.kind = :kind
        """,
    )
    fun observeHiddenCount(kind: VodKind): Flow<Int>

    @Query(
        """
        SELECT sourceId, 'MOVIE' AS kind, streamId AS itemId, name, posterUrl, rating FROM movies
        WHERE sourceId = :sourceId AND generation = :generation AND categoryId = :categoryId
        ORDER BY playlistOrder LIMIT :limit
        """,
    )
    suspend fun moviesIn(sourceId: Long, generation: Int, categoryId: String, limit: Int): List<Poster>

    @Query(
        """
        SELECT sourceId, 'SERIES' AS kind, seriesId AS itemId, name, posterUrl, rating FROM series
        WHERE sourceId = :sourceId AND generation = :generation AND categoryId = :categoryId
        ORDER BY playlistOrder LIMIT :limit
        """,
    )
    suspend fun seriesIn(sourceId: Long, generation: Int, categoryId: String, limit: Int): List<Poster>

    /** Title search. LIKE is case-insensitive for ASCII; [pattern] is `%words%`. */
    @Query(
        """
        SELECT m.sourceId, 'MOVIE' AS kind, m.streamId AS itemId, m.name, m.posterUrl, m.rating
        FROM movies m JOIN sources s ON s.id = m.sourceId AND s.vodGeneration = m.generation
        WHERE s.hidden = 0 AND m.name LIKE :pattern ESCAPE '\'
        ORDER BY m.playlistOrder LIMIT :limit
        """,
    )
    suspend fun searchMovies(pattern: String, limit: Int): List<Poster>

    @Query(
        """
        SELECT x.sourceId, 'SERIES' AS kind, x.seriesId AS itemId, x.name, x.posterUrl, x.rating
        FROM series x JOIN sources s ON s.id = x.sourceId AND s.vodGeneration = x.generation
        WHERE s.hidden = 0 AND x.name LIKE :pattern ESCAPE '\'
        ORDER BY x.playlistOrder LIMIT :limit
        """,
    )
    suspend fun searchSeries(pattern: String, limit: Int): List<Poster>

    @Query(
        """
        SELECT m.* FROM movies m JOIN sources s ON s.id = m.sourceId AND s.vodGeneration = m.generation
        WHERE m.sourceId = :sourceId AND m.streamId = :streamId LIMIT 1
        """,
    )
    suspend fun movie(sourceId: Long, streamId: String): MovieEntity?

    @Query(
        """
        SELECT x.* FROM series x JOIN sources s ON s.id = x.sourceId AND s.vodGeneration = x.generation
        WHERE x.sourceId = :sourceId AND x.seriesId = :seriesId LIMIT 1
        """,
    )
    suspend fun series(sourceId: Long, seriesId: String): SeriesEntity?

    /** Films you started and haven't finished, most recent first. */
    @Query(
        """
        SELECT m.sourceId, 'MOVIE' AS kind, m.streamId AS itemId, m.name, m.posterUrl, m.rating,
            p.positionMs, p.durationMs, NULL AS season, NULL AS episode
        FROM watch_progress p
        JOIN sources s ON s.id = p.sourceId AND s.hidden = 0
        JOIN movies m ON m.sourceId = p.sourceId AND m.streamId = p.itemId AND m.generation = s.vodGeneration
        WHERE p.kind = 'MOVIE' AND p.finished = 0 AND p.inContinue = 1
        ORDER BY p.updatedAt DESC LIMIT 30
        """,
    )
    fun observeContinueMovies(): Flow<List<Poster>>

    /** Series you're watching, by their latest episode, most recent first. */
    @Query(
        """
        SELECT x.sourceId, 'SERIES' AS kind, x.seriesId AS itemId, x.name, x.posterUrl, x.rating,
            p.positionMs, p.durationMs, p.season, p.episode
        FROM watch_progress p
        JOIN sources s ON s.id = p.sourceId AND s.hidden = 0
        JOIN series x ON x.sourceId = p.sourceId AND x.seriesId = p.seriesId AND x.generation = s.vodGeneration
        WHERE p.kind = 'SERIES' AND p.inContinue = 1
            AND p.updatedAt = (
                SELECT MAX(q.updatedAt) FROM watch_progress q
                WHERE q.sourceId = p.sourceId AND q.kind = 'SERIES' AND q.seriesId = p.seriesId
            )
        ORDER BY p.updatedAt DESC LIMIT 30
        """,
    )
    fun observeContinueSeries(): Flow<List<Poster>>

    /** The My List tab: films and series together, newest first. */
    @Query(
        """
        SELECT m.sourceId, 'MOVIE' AS kind, m.streamId AS itemId, m.name, m.posterUrl, m.rating, l.addedAt AS addedAt
        FROM my_list l
        JOIN sources s ON s.id = l.sourceId AND s.hidden = 0
        JOIN movies m ON m.sourceId = l.sourceId AND m.streamId = l.itemId AND m.generation = s.vodGeneration
        WHERE l.kind = 'MOVIE'
        UNION ALL
        SELECT x.sourceId, 'SERIES' AS kind, x.seriesId AS itemId, x.name, x.posterUrl, x.rating, l.addedAt AS addedAt
        FROM my_list l
        JOIN sources s ON s.id = l.sourceId AND s.hidden = 0
        JOIN series x ON x.sourceId = l.sourceId AND x.seriesId = l.itemId AND x.generation = s.vodGeneration
        WHERE l.kind = 'SERIES'
        ORDER BY addedAt DESC
        """,
    )
    fun observeMyListAll(): Flow<List<Poster>>

    @Query("DELETE FROM vod_categories WHERE sourceId = :sourceId AND generation != :keep")
    suspend fun deleteCategoriesExcept(sourceId: Long, keep: Int)

    @Query("DELETE FROM movies WHERE sourceId = :sourceId AND generation != :keep")
    suspend fun deleteMoviesExcept(sourceId: Long, keep: Int)

    @Query("DELETE FROM series WHERE sourceId = :sourceId AND generation != :keep")
    suspend fun deleteSeriesExcept(sourceId: Long, keep: Int)

    @Query("DELETE FROM movies WHERE sourceId = :sourceId AND generation = :generation")
    suspend fun deleteMoviesOf(sourceId: Long, generation: Int)

    @Query("DELETE FROM series WHERE sourceId = :sourceId AND generation = :generation")
    suspend fun deleteSeriesOf(sourceId: Long, generation: Int)

    @Query("UPDATE sources SET vodGeneration = :generation, vodRefreshed = :at WHERE id = :id")
    suspend fun markRefreshed(id: Long, generation: Int, at: Long)

    /** Everything of one source, user state included: used when the source is removed. */
    @Query("DELETE FROM vod_categories WHERE sourceId = :sourceId")
    suspend fun deleteAllCategories(sourceId: Long)

    @Query("DELETE FROM movies WHERE sourceId = :sourceId")
    suspend fun deleteAllMovies(sourceId: Long)

    @Query("DELETE FROM series WHERE sourceId = :sourceId")
    suspend fun deleteAllSeries(sourceId: Long)

    @Query("DELETE FROM watch_progress WHERE sourceId = :sourceId")
    suspend fun deleteAllProgress(sourceId: Long)

    @Query("DELETE FROM my_list WHERE sourceId = :sourceId")
    suspend fun deleteMyList(sourceId: Long)

    @Query("DELETE FROM hidden_vod_categories WHERE sourceId = :sourceId")
    suspend fun deleteHiddenCategories(sourceId: Long)
}

/** Watch progress, My List and hidden categories: user state, which survives refreshes. */
@Dao
interface VodUserDao {
    @Upsert
    suspend fun saveProgress(progress: WatchProgressEntity)

    @Query("SELECT * FROM watch_progress WHERE sourceId = :sourceId AND kind = :kind AND itemId = :itemId")
    fun observeProgress(sourceId: Long, kind: VodKind, itemId: String): Flow<WatchProgressEntity?>

    @Query("SELECT * FROM watch_progress WHERE sourceId = :sourceId AND kind = :kind AND itemId = :itemId")
    suspend fun progress(sourceId: Long, kind: VodKind, itemId: String): WatchProgressEntity?

    /** Every episode of a series you've played, most recent first. */
    @Query(
        """
        SELECT * FROM watch_progress WHERE sourceId = :sourceId AND kind = 'SERIES' AND seriesId = :seriesId
        ORDER BY updatedAt DESC
        """,
    )
    fun observeSeriesProgress(sourceId: Long, seriesId: String): Flow<List<WatchProgressEntity>>

    @Query("UPDATE watch_progress SET inContinue = 0 WHERE sourceId = :sourceId AND kind = 'MOVIE' AND itemId = :itemId")
    suspend fun dismissMovie(sourceId: Long, itemId: String)

    @Query("UPDATE watch_progress SET inContinue = 0 WHERE sourceId = :sourceId AND kind = 'SERIES' AND seriesId = :seriesId")
    suspend fun dismissSeries(sourceId: Long, seriesId: String)

    @Query("SELECT EXISTS(SELECT 1 FROM my_list WHERE sourceId = :sourceId AND kind = :kind AND itemId = :itemId)")
    fun observeInMyList(sourceId: Long, kind: VodKind, itemId: String): Flow<Boolean>

    @Query("SELECT EXISTS(SELECT 1 FROM my_list WHERE sourceId = :sourceId AND kind = :kind AND itemId = :itemId)")
    suspend fun inMyList(sourceId: Long, kind: VodKind, itemId: String): Boolean

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun addToMyList(item: MyListEntity)

    @Query("DELETE FROM my_list WHERE sourceId = :sourceId AND kind = :kind AND itemId = :itemId")
    suspend fun removeFromMyList(sourceId: Long, kind: VodKind, itemId: String)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun hideCategory(category: HiddenVodCategoryEntity)

    @Query(
        """
        DELETE FROM hidden_vod_categories
        WHERE kind = :kind AND sourceId IN (SELECT id FROM sources WHERE hidden = 0)
        """,
    )
    suspend fun showAllCategories(kind: VodKind)

    @Query("DELETE FROM hidden_vod_categories WHERE sourceId = :sourceId AND kind = :kind AND categoryId = :categoryId")
    suspend fun showCategory(sourceId: Long, kind: VodKind, categoryId: String)
}
