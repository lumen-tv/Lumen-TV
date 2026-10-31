package com.hayat.lumen.ui.vod

import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.focusProperties
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.MutableIntState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.foundation.BorderStroke
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.data.db.Poster
import com.hayat.lumen.data.db.VodCategoryRow
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.vod.VodSync
import com.hayat.lumen.ui.components.LumenButton
import com.hayat.lumen.ui.components.QualityTag
import com.hayat.lumen.util.CategoryNames
import com.hayat.lumen.ui.components.PosterCard
import com.hayat.lumen.ui.components.ContinueCard
import com.hayat.lumen.ui.components.SeeAllCard
import com.hayat.lumen.ui.components.Tab
import com.hayat.lumen.ui.components.TopTabs
import com.hayat.lumen.ui.components.Ambient
import com.hayat.lumen.ui.components.formatCount
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.ui.theme.SafeArea

/**
 * The Movies or Series tab, like the Apple TV app: the focused title fills the top of the
 * screen (backdrop, title, year, genre, plot), with rows of posters below. Continue watching
 * and My List come first, then the provider's categories. Hold OK on a poster to add it to
 * My List (or, in Continue watching, to remove it from there).
 */
@OptIn(ExperimentalFoundationApi::class) // LocalBringIntoViewSpec
@Composable
fun VodBrowseScreen(
    kind: VodKind,
    onTab: (Tab) -> Unit,
    onOpen: (Poster) -> Unit,
    onSeeAll: (VodCategoryRow) -> Unit,
    onSearch: () -> Unit,
) {
    val container = LocalAppContainer.current
    val vm = viewModel(key = kind.name) { VodBrowseViewModel(container.vod, kind) }
    val categories by vm.categories.collectAsStateWithLifecycle()
    val continueWatching by vm.continueWatching.collectAsStateWithLifecycle()
    val hiddenCount by vm.hiddenCount.collectAsStateWithLifecycle()
    val sync by vm.sync.collectAsStateWithLifecycle()
    val hero by vm.hero.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val noun = if (kind == VodKind.MOVIE) "films" else "series"

    // Focus comes back to the poster you opened. Keys are "<row>|<poster>".
    var lastFocus by rememberSaveable { mutableStateOf<String?>(null) }
    val restore = remember { FocusRequester() }
    val first = remember { FocusRequester() }
    val tabsFocus = remember { FocusRequester() }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    // The rows' own (horizontal) scrolling keeps the default; see RowItem.
    val rowSpec = LocalBringIntoViewSpec.current

    fun toggleMyList(poster: Poster) = vm.toggleMyList(poster) { added ->
        Toast.makeText(context, if (added) "Added to My List" else "Removed from My List", Toast.LENGTH_SHORT).show()
    }

    @Composable
    fun Card(rowKey: String, poster: Poster, isFirst: Boolean, rowFocus: Modifier, wide: Boolean = false, onLongClick: () -> Unit) {
        val key = "$rowKey|${poster.key}"
        val modifier = rowFocus
                .then(if (key == lastFocus) Modifier.focusRequester(restore) else Modifier)
                .then(if (isFirst) Modifier.focusRequester(first) else Modifier)
                .onFocusChanged {
                    if (it.isFocused) {
                        lastFocus = key
                        vm.focus(poster)
                    }
                }
        if (wide) {
            // The backdrop comes from the stored series row, or get_vod_info for a film (cached).
            val backdrop by produceState<String?>(null, poster.key) { value = vm.backdrop(poster) }
            ContinueCard(poster, backdrop, onClick = { onOpen(poster) }, onLongClick = onLongClick, modifier = modifier)
        } else {
            PosterCard(poster = poster, onClick = { onOpen(poster) }, onLongClick = onLongClick, modifier = modifier)
        }
    }

    Ambient {
        // Big, like the Apple TV app: the focused title's backdrop fills most of the screen.
        Backdrop(hero, widthFraction = 1f, heightFraction = 0.85f, leftFade = 0.55f)
        Column(Modifier.fillMaxSize().padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical)) {
            TopTabs(
                selected = if (kind == VodKind.MOVIE) Tab.MOVIES else Tab.SERIES,
                onSelect = { if (it == Tab.SEARCH) onSearch() else onTab(it) },
                modifier = Modifier.focusRequester(tabsFocus),
            ) {
                val status = when (val s = sync) {
                    is VodSync.Running -> "Updating films and series… ${formatCount(s.movies + s.series)}"
                    is VodSync.Failed -> s.message
                    VodSync.Idle -> ""
                }
                Text(status, style = MaterialTheme.typography.bodySmall, color = LumenColors.TextTertiary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }

            val rows = categories
            when {
                rows == null -> Spacer(Modifier.weight(1f))
                rows.isEmpty() && continueWatching.isEmpty() -> {
                    Spacer(Modifier.height(96.dp))
                    Text(
                        if (sync is VodSync.Running) "Loading $noun…" else "No $noun yet",
                        style = MaterialTheme.typography.displaySmall,
                        color = LumenColors.TextPrimary,
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        when {
                            sync is VodSync.Running -> "The first load takes a minute. They'll appear here when it's done."
                            hiddenCount > 0 -> "Every category is hidden."
                            else -> "Films and series come from an Xtream login. Add one as a playlist, then come back here."
                        },
                        style = MaterialTheme.typography.bodyLarge,
                        color = LumenColors.TextSecondary,
                    )
                    if (hiddenCount > 0) {
                        Spacer(Modifier.height(24.dp))
                        LumenButton(text = "Show hidden categories", onClick = vm::showHidden)
                    }
                }
                else -> {
                    HeroText(hero, Modifier.weight(1f).fillMaxWidth().padding(bottom = 8.dp), plotLines = 2)
                    // The list's items in order, so a focused row can scroll itself to the top.
                    val keys = buildList {
                        if (rows.size > 1) add("chips")
                        if (continueWatching.isNotEmpty()) add("continue")
                        rows.forEach { add("${it.sourceId}/${it.categoryId}") }
                        if (hiddenCount > 0) add("hidden")
                    }

                    /**
                     * One item of the list. When something in it takes focus, the whole item scrolls to the
                     * top of the list, title and all. Compose's default only scrolls until the focused card
                     * itself fits, which cut off the row's title and the top of the enlarged focused poster.
                     */
                    @Composable
                    fun RowItem(key: String, content: @Composable () -> Unit) {
                        CompositionLocalProvider(LocalBringIntoViewSpec provides rowSpec) {
                            Box(Modifier.onFocusChanged { state ->
                                if (state.hasFocus) {
                                    val index = keys.indexOf(key)
                                    // A few pixels of the row above stay in the list (in its transparent bottom padding,
                                    // so nothing shows): only rows in the list can take focus, so Up still finds it.
                                    if (index >= 0) scope.launch { listState.animateScrollToItem(index, if (index > 0) -PeekPx else 0) }
                                }
                            }) { content() }
                        }
                    }

                    // CompositionLocalProvider is like SwiftUI's .environment(): it applies to everything inside.
                    CompositionLocalProvider(LocalBringIntoViewSpec provides NoAutoScroll) {
                    LazyColumn(
                        state = listState,
                        modifier = Modifier.fillMaxWidth().height(RowsHeight),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        // Every category as a small pill, a quick way to "See all" of one.
                        if (rows.size > 1) {
                            item(key = "chips") { RowItem("chips") {
                                LazyRow(
                                    modifier = Modifier.fillMaxWidth().focusRestorer(),
                                    contentPadding = PaddingValues(vertical = 12.dp, horizontal = 4.dp),
                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                ) {
                                    items(rows, key = { "${it.sourceId}/${it.categoryId}" }) { row ->
                                        CategoryChip(row.name, row.itemCount, onClick = { onSeeAll(row) })
                                    }
                                }
                            } }
                        }
                        if (continueWatching.isNotEmpty()) {
                            item(key = "continue") { RowItem("continue") {
                                PosterRow("Continue watching", "Hold OK to remove") { focus ->
                                    itemsIndexed(continueWatching, key = { _, p -> p.key }) { i, p ->
                                        Card("continue", p, isFirst = i == 0, focus.item(i), wide = true) { vm.removeFromContinue(p) }
                                    }
                                }
                            } }
                        }
                        val categoriesFirst = continueWatching.isEmpty()
                        itemsIndexed(rows, key = { _, r -> "${r.sourceId}/${r.categoryId}" }) { rowIndex, row ->
                            val rowKey = "${row.sourceId}/${row.categoryId}"
                            val posters by produceState<List<Poster>>(emptyList(), row.sourceId, row.categoryId, row.generation) {
                                value = vm.posters(row, fillsHero = rowIndex == 0)
                            }
                            val name = remember(row.name) { CategoryNames.display(row.name) }
                            RowItem(rowKey) {
                            PosterRow(name.title, (name.tags + formatCount(row.itemCount)).joinToString("  ·  ")) { focus ->
                                itemsIndexed(posters, key = { _, p -> p.key }) { i, p ->
                                    Card(rowKey, p, isFirst = categoriesFirst && rowIndex == 0 && i == 0, focus.item(i)) { toggleMyList(p) }
                                }
                                if (posters.isNotEmpty()) item(key = "all") {
                                    SeeAllCard(row.itemCount, onClick = { onSeeAll(row) }, modifier = focus.item(posters.size))
                                }
                            }
                            }
                        }
                        if (hiddenCount > 0) {
                            item(key = "hidden") { RowItem("hidden") {
                                Row(Modifier.padding(vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                                    LumenButton(
                                        text = if (hiddenCount == 1) "Show 1 hidden category" else "Show $hiddenCount hidden categories",
                                        onClick = vm::showHidden,
                                    )
                                }
                            } }
                        }
                    }
                    }
                }
            }
        }
    }

    // First focus: the poster you came back from, else the first poster, else the tabs.
    var focusDone by remember { mutableStateOf(false) }
    LaunchedEffect(categories != null) {
        if (focusDone || categories == null) return@LaunchedEffect
        // A category row's posters arrive a few frames after the row itself.
        repeat(20) {
            withFrameNanos { }
            val target = if (lastFocus != null) restore else first
            if (runCatching { target.requestFocus() }.isSuccess) {
                focusDone = true
                return@LaunchedEffect
            }
        }
        focusDone = runCatching { tabsFocus.requestFocus() }.isSuccess
    }
}

/**
 * Where focus lands when it enters a poster row: Down = the row's first poster (the row scrolls back
 * to the start), Up = the poster you were last on in that row. Each poster takes [item] (its index).
 */
private class RowFocus(private val last: MutableIntState) {
    val first = FocusRequester()
    val remembered = FocusRequester()

    fun item(index: Int): Modifier = Modifier
        .then(if (index == 0) Modifier.focusRequester(first) else Modifier)
        .then(if (index == last.intValue) Modifier.focusRequester(remembered) else Modifier)
        .onFocusChanged { if (it.isFocused) last.intValue = index }
}

internal const val PeekPx = 4

/** For the list of rows: never scroll by itself to show a focused card (RowItem scrolls whole rows instead). */
@OptIn(ExperimentalFoundationApi::class)
internal object NoAutoScroll : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) = 0f
}

/** A titled row of posters, see [RowFocus]. */
@Composable
private fun PosterRow(
    title: String,
    detail: String?,
    content: LazyListScope.(RowFocus) -> Unit,
) {
    // rememberSaveable: the LazyColumn keeps this while the row is scrolled off screen.
    val last = rememberSaveable { mutableIntStateOf(0) }
    val focus = remember { RowFocus(last) }
    val rowState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    Column {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = LumenColors.TextPrimary, maxLines = 1)
            if (detail != null) {
                Spacer(Modifier.width(12.dp))
                Text(detail, style = MaterialTheme.typography.bodySmall, color = LumenColors.TextTertiary, maxLines = 1)
            }
        }
        LazyRow(
            state = rowState,
            modifier = Modifier
                .fillMaxWidth()
                // Unlike SwiftUI, Compose lets a container redirect focus as it comes in: onEnter runs
                // before any child is focused, and requestFocus() there picks the child instead.
                .focusProperties {
                    onEnter = {
                        val target = when (requestedFocusDirection) {
                            FocusDirection.Down -> 0
                            FocusDirection.Up -> last.intValue
                            else -> -1
                        }
                        if (target >= 0) {
                            val requester = if (target == 0) focus.first else focus.remembered
                            val ready = if (target == 0) rowState.firstVisibleItemIndex == 0
                            else rowState.layoutInfo.visibleItemsInfo.any { it.index == target }
                            if (ready) {
                                requester.requestFocus()
                            } else {
                                // The poster isn't laid out yet: scroll to it, then focus it.
                                cancelFocusChange()
                                scope.launch {
                                    rowState.scrollToItem(target)
                                    withFrameNanos { }
                                    runCatching { requester.requestFocus() }
                                }
                            }
                        }
                    }
                }
                .focusGroup(),
            // Room for the focused card's lift and shadow.
            contentPadding = PaddingValues(vertical = 14.dp, horizontal = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(18.dp),
        ) { content(focus) }
    }
}

/** One row plus the next row's title peeking in, so you can tell there's more below. */
private val RowsHeight = 290.dp

/** A category as a glass pill: its tidied name, its quality tag and how many titles it has. */
@Composable
private fun CategoryChip(name: String, count: Int, onClick: () -> Unit) {
    val display = remember(name) { CategoryNames.display(name) }
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = LumenColors.Glass,
            contentColor = LumenColors.TextPrimary,
            focusedContainerColor = LumenColors.TextPrimary,
            focusedContentColor = LumenColors.Background,
        ),
        border = ClickableSurfaceDefaults.border(
            border = Border(BorderStroke(1.dp, LumenColors.GlassEdge), shape = RoundedCornerShape(50)),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.05f),
    ) {
        Row(
            Modifier.padding(horizontal = 18.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(display.title, style = MaterialTheme.typography.titleSmall, maxLines = 1)
            display.tags.forEach { QualityTag(it, color = LocalContentColor.current.copy(alpha = 0.7f)) }
            Text(formatCount(count), style = MaterialTheme.typography.labelMedium, color = LocalContentColor.current.copy(alpha = 0.55f))
        }
    }
}
