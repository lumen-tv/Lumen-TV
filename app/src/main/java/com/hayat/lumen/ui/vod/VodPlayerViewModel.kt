package com.hayat.lumen.ui.vod

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.ratings.OmdbClient
import com.hayat.lumen.data.settings.Preferences
import com.hayat.lumen.data.skip.EpisodeRef
import com.hayat.lumen.data.skip.SkipSegment
import com.hayat.lumen.data.skip.SkipTimesClient
import com.hayat.lumen.data.vod.NextUp
import com.hayat.lumen.data.vod.VodPlayable
import com.hayat.lumen.data.vod.VodRepository
import com.hayat.lumen.data.xtream.XtreamEpisode
import com.hayat.lumen.ui.components.episodeLabel
import com.hayat.lumen.util.VodNames
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** What's playing: the stream, where to start, the titles for the overlay, and the next episode. */
data class NowPlaying(
    val item: VodPlayable,
    val startMs: Long,
    val title: String,
    val subtitle: String?,
    val next: XtreamEpisode?,
    val nextLabel: String?,
)

/** Loads a film or an episode for the player, and moves on to the next episode. */
class VodPlayerViewModel(
    private val vod: VodRepository,
    private val skipTimes: SkipTimesClient,
    private val omdb: OmdbClient,
    private val prefs: Preferences,
    private val sourceId: Long,
    kind: VodKind,
    itemId: String,
    private val seriesId: String?,
    startOver: Boolean,
) : ViewModel() {
    private val _now = MutableStateFlow<NowPlaying?>(null)
    val now: StateFlow<NowPlaying?> = _now
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error

    /** Intro, recap and credit times for the episode playing; empty when the databases don't have it. */
    private val _skips = MutableStateFlow<List<SkipSegment>>(emptyList())
    val skips: StateFlow<List<SkipSegment>> = _skips

    private var episodes: List<XtreamEpisode> = emptyList()
    private var seriesTitle: String = ""
    private var seriesYear: Int? = null
    private var tmdbId: String? = null
    private var imdbId: String? = null
    private var idsLooked = false
    private var skipJob: Job? = null

    init {
        viewModelScope.launch {
            try {
                if (kind == VodKind.MOVIE) loadMovie(itemId, startOver) else loadEpisode(itemId, startOver)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _error.value = e.message ?: "Couldn't open this title."
            }
        }
    }

    private suspend fun loadMovie(streamId: String, startOver: Boolean) {
        val item = vod.moviePlayable(sourceId, streamId) ?: run {
            _error.value = "This film is no longer available."
            return
        }
        val start = if (startOver) 0L else VodRepository.resumePosition(vod.progressNow(sourceId, VodKind.MOVIE, streamId)) ?: 0L
        val name = VodNames.display(item.title)
        _now.value = NowPlaying(item, start, name.title, name.year?.toString(), next = null, nextLabel = null)
    }

    private suspend fun loadEpisode(episodeId: String, startOver: Boolean) {
        val seriesId = seriesId ?: return
        val series = vod.series(sourceId, seriesId)
        val name = series?.name?.let(VodNames::display)
        seriesTitle = name?.title.orEmpty()
        seriesYear = name?.year ?: series?.releaseDate?.take(4)?.toIntOrNull()
        val info = vod.seriesInfo(sourceId, seriesId)
        episodes = info.episodes
        tmdbId = info.tmdbId
        val episode = episodes.firstOrNull { it.id == episodeId } ?: run {
            _error.value = "This episode is no longer available."
            return
        }
        play(episode, startOver)
    }

    private suspend fun play(episode: XtreamEpisode, startOver: Boolean) {
        val seriesId = seriesId ?: return
        val login = vod.login(sourceId) ?: return
        val item = vod.episodePlayable(login, sourceId, seriesId, episode)
        val start = if (startOver) 0L else VodRepository.resumePosition(vod.progressNow(sourceId, VodKind.SERIES, episode.id)) ?: 0L
        val next = NextUp.after(episodes, episode.id)
        _now.value = NowPlaying(
            item = item,
            startMs = start,
            title = seriesTitle.ifEmpty { episode.title.orEmpty() },
            subtitle = "${episodeLabel(episode.season, episode.episode)}  ${episode.title?.let(::cleanEpisodeTitle) ?: "Episode ${episode.episode}"}".trim(),
            next = next,
            nextLabel = next?.let { "${episodeLabel(it.season, it.episode)}  ${it.title?.let(::cleanEpisodeTitle) ?: "Episode ${it.episode}"}".trim() },
        )
        loadSkips(episode)
    }

    /** Looks up where this episode's intro, recap and credits are. Runs beside playback; nothing waits for it. */
    private fun loadSkips(episode: XtreamEpisode) {
        _skips.value = emptyList()
        skipJob?.cancel()
        skipJob = viewModelScope.launch {
            try {
                if (!idsLooked && seriesTitle.isNotEmpty()) {
                    idsLooked = true
                    // OMDb is only asked when the user has a key; its answer is usually cached from the series page.
                    imdbId = omdb.ratings(prefs.omdbKey.value, seriesTitle, seriesYear, series = true)?.imdbId
                    if (tmdbId == null) tmdbId = skipTimes.tmdbIdFor(seriesTitle, seriesYear)
                }
                _skips.value = skipTimes.episode(EpisodeRef(tmdbId, imdbId, episode.season, episode.episode, episode.durationSecs))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // No times: no button.
            }
        }
    }

    fun playNext() {
        val next = _now.value?.next ?: return
        viewModelScope.launch { play(next, startOver = false) }
    }

    fun save(positionMs: Long, durationMs: Long) {
        _now.value?.let { vod.saveProgress(it.item, positionMs, durationMs) }
    }
}
