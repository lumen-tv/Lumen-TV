package com.hayat.lumen.ui.vod

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.data.ImportException
import com.hayat.lumen.data.db.Poster
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.db.WatchProgressEntity
import com.hayat.lumen.data.vod.NextUp
import com.hayat.lumen.data.vod.VodRepository
import com.hayat.lumen.data.xtream.XtreamEpisode
import com.hayat.lumen.data.xtream.XtreamSeriesInfo
import com.hayat.lumen.ui.components.LumenButton
import com.hayat.lumen.ui.components.Ambient
import com.hayat.lumen.data.ratings.OmdbClient
import com.hayat.lumen.R
import com.hayat.lumen.ui.components.LumenCard
import com.hayat.lumen.ui.components.Pills
import com.hayat.lumen.ui.components.ProgrammeProgress
import com.hayat.lumen.ui.components.episodeLabel
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.ui.theme.SafeArea
import com.hayat.lumen.util.VodNames
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

sealed interface EpisodesState {
    data object Loading : EpisodesState
    data class Loaded(val info: XtreamSeriesInfo) : EpisodesState
    data class Failed(val message: String) : EpisodesState
}

class SeriesDetailViewModel(
    private val vod: VodRepository,
    private val omdb: OmdbClient,
    private val omdbKey: () -> String?,
    private val sourceId: Long,
    private val seriesId: String,
) : ViewModel() {
    private val _hero = MutableStateFlow<HeroInfo?>(null)
    val hero: StateFlow<HeroInfo?> = _hero
    private val _episodes = MutableStateFlow<EpisodesState>(EpisodesState.Loading)
    val episodes: StateFlow<EpisodesState> = _episodes

    val progress: StateFlow<List<WatchProgressEntity>> = vod.seriesProgress(sourceId, seriesId)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val inMyList: StateFlow<Boolean> = vod.inMyList(sourceId, VodKind.SERIES, seriesId)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), false)

    init {
        viewModelScope.launch {
            val series = vod.series(sourceId, seriesId) ?: return@launch
            val full = vod.hero(Poster(sourceId, VodKind.SERIES, seriesId, series.name, series.posterUrl, series.rating))
            _hero.value = full
            _hero.value = omdb.addRatings(full, omdbKey(), series = true)
        }
        load()
    }

    fun load() {
        _episodes.value = EpisodesState.Loading
        viewModelScope.launch {
            _episodes.value = try {
                val info = vod.seriesInfo(sourceId, seriesId)
                if (info.episodes.isEmpty()) EpisodesState.Failed("No episodes available yet.") else EpisodesState.Loaded(info)
            } catch (e: CancellationException) {
                throw e
            } catch (e: ImportException) {
                EpisodesState.Failed(e.message ?: "Couldn't load the episodes.")
            } catch (e: Exception) {
                EpisodesState.Failed("Couldn't load the episodes.")
            }
        }
    }

    fun toggleMyList() {
        viewModelScope.launch { vod.toggleMyList(sourceId, VodKind.SERIES, seriesId) }
    }
}

/**
 * A series' page: backdrop and details, a Play button that picks up where you are
 * ("Resume S1 · E3"), then seasons and their episodes with how far you got in each.
 */
@Composable
fun SeriesDetailScreen(sourceId: Long, seriesId: String, onPlay: (episodeId: String) -> Unit) {
    val container = LocalAppContainer.current
    val vm = viewModel { SeriesDetailViewModel(container.vod, container.omdb, { container.prefs.omdbKey.value }, sourceId, seriesId) }
    val hero by vm.hero.collectAsStateWithLifecycle()
    val state by vm.episodes.collectAsStateWithLifecycle()
    val progress by vm.progress.collectAsStateWithLifecycle()
    val inMyList by vm.inMyList.collectAsStateWithLifecycle()
    val playFocus = remember { FocusRequester() }

    val episodes = (state as? EpisodesState.Loaded)?.info?.episodes.orEmpty()
    val pick = remember(episodes, progress) { NextUp.pick(episodes, progress) }
    val seasons = remember(episodes) { episodes.map { it.season }.distinct() }
    var season by rememberSaveable { mutableStateOf<Int?>(null) }
    LaunchedEffect(pick?.episode?.season) { if (season == null) season = pick?.episode?.season }
    val shown = season ?: seasons.firstOrNull()

    Ambient {
        Backdrop(hero, widthFraction = 1f, heightFraction = 1f, leftFade = 0.6f)
        Column(
            Modifier.fillMaxSize().padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical),
            verticalArrangement = Arrangement.Bottom,
        ) {
            HeroText(hero, Modifier.fillMaxWidth(), plotLines = 2)
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                LumenButton(
                    text = when {
                        pick == null -> "Play"
                        pick.resumeMs != null -> "Resume ${episodeLabel(pick.episode.season, pick.episode.episode)}"
                        else -> "Play ${episodeLabel(pick.episode.season, pick.episode.episode)}"
                    },
                    onClick = { pick?.let { onPlay(it.episode.id) } },
                    enabled = pick != null,
                    primary = true,
                    icon = R.drawable.ic_play,
                    modifier = Modifier.focusRequester(playFocus),
                )
                LumenButton(
                    text = "",
                    onClick = vm::toggleMyList,
                    icon = if (inMyList) R.drawable.ic_heart else R.drawable.ic_heart_outline,
                )
                // Weighted, so these messages take only the room the scores leave (weighted children are measured last).
                (state as? EpisodesState.Failed)?.let { failed ->
                    Text(
                        failed.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = LumenColors.TextSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    LumenButton(text = "Try again", onClick = vm::load)
                }
                if (state is EpisodesState.Loading) {
                    Text(
                        "Loading episodes…",
                        style = MaterialTheme.typography.bodyMedium,
                        color = LumenColors.TextTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                // The scores, big, at the right of the buttons: the episodes leave no room for a row of their own.
                hero?.ratings?.let {
                    Spacer(Modifier.weight(1f))
                    RatingsPanel(it, ageCaption = false)
                }
            }
            if (seasons.isNotEmpty()) {
                Spacer(Modifier.height(16.dp))
                if (seasons.size > 1) {
                    Pills(
                        labels = seasons.map { "Season $it" },
                        selected = seasons.indexOf(shown),
                        onSelect = { season = seasons[it] },
                        onFocus = { season = seasons[it] },
                    )
                    Spacer(Modifier.height(4.dp))
                }
                val inSeason = episodes.filter { it.season == shown }
                val rowState = rememberLazyListState()
                LaunchedEffect(shown) {
                    val i = inSeason.indexOfFirst { it.id == pick?.episode?.id }
                    rowState.scrollToItem(i.coerceAtLeast(0))
                }
                LazyRow(
                    state = rowState,
                    modifier = Modifier.fillMaxWidth().focusRestorer(),
                    contentPadding = PaddingValues(vertical = 14.dp, horizontal = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(20.dp),
                ) {
                    items(inSeason, key = { it.id }) { ep ->
                        EpisodeCard(
                            episode = ep,
                            progress = progress.firstOrNull { it.itemId == ep.id },
                            fallbackImage = hero?.backdropUrl,
                            seriesTitle = hero?.title,
                            onClick = { onPlay(ep.id) },
                        )
                    }
                }
            }
        }
    }

    LaunchedEffect(Unit) { runCatching { playFocus.requestFocus() } }
}

@Composable
private fun EpisodeCard(episode: XtreamEpisode, progress: WatchProgressEntity?, fallbackImage: String?, seriesTitle: String?, onClick: () -> Unit) {
    val container = LocalAppContainer.current
    Column(Modifier.width(EpisodeWidth)) {
        LumenCard(onClick = onClick, modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f)) {
            Box(Modifier.fillMaxSize().background(LumenColors.Glass)) {
                val image = episode.imageUrl ?: fallbackImage
                if (image != null) {
                    AsyncImage(
                        model = image,
                        contentDescription = null,
                        imageLoader = container.images,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                val fraction = progress?.let {
                    if (it.finished) 1f else if (it.durationMs > 0) it.positionMs.toFloat() / it.durationMs else null
                }
                if (fraction != null) {
                    Box(
                        Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f))))
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                    ) {
                        ProgrammeProgress(fraction, color = Color.White, height = 3.dp)
                    }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "${episode.episode}. ${VodNames.episode(episode.title, seriesTitle) ?: "Episode ${episode.episode}"}",
            style = MaterialTheme.typography.labelLarge,
            color = LumenColors.TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        episode.durationSecs?.let {
            Text(
                formatRuntime((it / 60).toInt().coerceAtLeast(1)),
                style = MaterialTheme.typography.bodySmall,
                color = LumenColors.TextTertiary,
            )
        }
    }
}

private val EpisodeWidth = 220.dp
