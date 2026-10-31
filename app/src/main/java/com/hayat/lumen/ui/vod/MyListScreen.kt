package com.hayat.lumen.ui.vod

import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.data.db.Poster
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.vod.VodRepository
import com.hayat.lumen.ui.components.Ambient
import com.hayat.lumen.ui.components.Pills
import com.hayat.lumen.ui.components.PosterCard
import com.hayat.lumen.ui.components.Tab
import com.hayat.lumen.ui.components.TopTabs
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.ui.theme.SafeArea
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.transformLatest
import kotlinx.coroutines.launch

/** The My List tab: everything you saved, films and series together, and the hero for the focused one. */
@OptIn(ExperimentalCoroutinesApi::class)
class MyListViewModel(private val vod: VodRepository) : ViewModel() {
    /** null until the first query returns, so the tab doesn't flash its empty state. */
    val items: StateFlow<List<Poster>?> = vod.myListAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private val focused = MutableStateFlow<Poster?>(null)

    /** Same as the Movies and Series tabs: quick info at once, the full info once focus rests. */
    val hero = focused
        .transformLatest { poster ->
            if (poster == null) return@transformLatest
            emit(poster.quickHero())
            delay(450)
            emit(vod.hero(poster))
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun focus(poster: Poster) {
        focused.value = poster
    }

    fun remove(poster: Poster) {
        viewModelScope.launch { vod.toggleMyList(poster.sourceId, poster.kind, poster.itemId) }
    }
}

/** Which titles the tab shows. */
private enum class MyListFilter(val label: String) { ALL("All"), FILMS("Films"), SERIES("Series") }

@OptIn(ExperimentalFoundationApi::class) // LocalBringIntoViewSpec
@Composable
fun MyListScreen(onTab: (Tab) -> Unit, onOpen: (Poster) -> Unit, onSearch: () -> Unit) {
    val container = LocalAppContainer.current
    val vm = viewModel { MyListViewModel(container.vod) }
    val items by vm.items.collectAsStateWithLifecycle()
    val hero by vm.hero.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var filter by rememberSaveable { mutableStateOf(MyListFilter.ALL) }
    val all = items.orEmpty()
    val films = all.filter { it.kind == VodKind.MOVIE }
    val series = all.filter { it.kind == VodKind.SERIES }
    val shown = when (filter) {
        MyListFilter.ALL -> all
        MyListFilter.FILMS -> films
        MyListFilter.SERIES -> series
    }

    // Focus comes back to the poster you opened (or, after a removal, its neighbour).
    var lastFocus by rememberSaveable { mutableStateOf<String?>(null) }
    val restore = remember { FocusRequester() }
    val tabsFocus = remember { FocusRequester() }
    val gridState = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    var shownRow by remember { mutableIntStateOf(0) }
    // Set on opening the tab and after a removal: the grid takes focus once the list updates.
    // (Not on every change: moving along the filter pills changes the list too.)
    var refocus by remember { mutableStateOf(true) }

    Ambient {
        Backdrop(hero, widthFraction = 1f, heightFraction = 0.85f, leftFade = 0.55f)
        Column(Modifier.fillMaxSize().padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical)) {
            TopTabs(
                selected = Tab.MY_LIST,
                onSelect = { if (it == Tab.SEARCH) onSearch() else onTab(it) },
                modifier = Modifier.focusRequester(tabsFocus),
            )
            if (items != null && all.isEmpty()) {
                Spacer(Modifier.height(96.dp))
                Text("Nothing in My List yet", style = MaterialTheme.typography.displaySmall, color = LumenColors.TextPrimary)
                Spacer(Modifier.height(12.dp))
                Text(
                    "Hold OK on any film or series poster to add it here.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = LumenColors.TextSecondary,
                )
                return@Column
            }
            HeroText(hero, Modifier.weight(1f).fillMaxWidth().padding(bottom = 8.dp), plotLines = 2)
            Pills(
                labels = MyListFilter.entries.map { f ->
                    val count = when (f) {
                        MyListFilter.ALL -> all.size
                        MyListFilter.FILMS -> films.size
                        MyListFilter.SERIES -> series.size
                    }
                    "${f.label}  $count"
                },
                selected = filter.ordinal,
                // OK picks a filter (not focus: Up from the grid can land on any pill).
                onSelect = { filter = MyListFilter.entries[it] },
                modifier = Modifier.padding(vertical = 6.dp),
            )
            // As on the Movies and Series tabs: the grid never nudges itself to a focused poster; the
            // focused poster's whole row scrolls to the top (a sliver of the row above stays, so Up finds it).
            CompositionLocalProvider(LocalBringIntoViewSpec provides NoAutoScroll) {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(Columns),
                    state = gridState,
                    modifier = Modifier.fillMaxWidth().height(GridHeight),
                    contentPadding = PaddingValues(vertical = 14.dp, horizontal = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(18.dp),
                    verticalArrangement = Arrangement.spacedBy(22.dp),
                ) {
                    itemsIndexed(shown, key = { _, p -> p.key }) { i, p ->
                        PosterCard(
                            poster = p,
                            onClick = { onOpen(p) },
                            onLongClick = {
                                // Keep focus in the grid: on the next poster, else the one before.
                                lastFocus = (shown.getOrNull(i + 1) ?: shown.getOrNull(i - 1))?.key
                                refocus = true
                                vm.remove(p)
                                Toast.makeText(context, "Removed from My List", Toast.LENGTH_SHORT).show()
                            },
                            width = PosterGridWidth,
                            modifier = Modifier
                                // Right at the end of a row stays put (Compose would jump to the row above).
                                .then(if (i % Columns == Columns - 1 || i == shown.lastIndex) Modifier.focusProperties { right = FocusRequester.Cancel } else Modifier)
                                .then(if (p.key == lastFocus) Modifier.focusRequester(restore) else Modifier)
                                .onFocusChanged {
                                    if (it.isFocused) {
                                        lastFocus = p.key
                                        vm.focus(p)
                                        val row = i / Columns
                                        if (row != shownRow || gridState.firstVisibleItemIndex / Columns != row) {
                                            shownRow = row
                                            scope.launch { gridState.animateScrollToItem(row * Columns, if (row > 0) -PeekPx else 0) }
                                        }
                                    }
                                },
                        )
                    }
                }
            }
        }
    }

    // First focus: the poster you came back from, else the first one; after a removal, its neighbour.
    LaunchedEffect(shown, refocus) {
        if (items == null || !refocus) return@LaunchedEffect
        refocus = false
        if (shown.none { it.key == lastFocus }) lastFocus = shown.firstOrNull()?.key
        repeat(10) {
            withFrameNanos { }
            val target = if (lastFocus != null) restore else tabsFocus
            if (runCatching { target.requestFocus() }.isSuccess) return@LaunchedEffect
        }
    }
}

private const val Columns = 6

/** Six posters across the safe area (the Movies and Series rows use 130 dp). */
private val PosterGridWidth = 124.dp

/** One row of posters plus a peek of the next. */
private val GridHeight = 250.dp
