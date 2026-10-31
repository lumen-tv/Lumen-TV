package com.hayat.lumen.ui

import androidx.compose.animation.ContentTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.ui.addsource.AddSourceScreen
import com.hayat.lumen.ui.guide.GuideScreen
import com.hayat.lumen.ui.home.HomeScreen
import com.hayat.lumen.ui.live.LiveScreen
import com.hayat.lumen.ui.player.PlayerScreen
import com.hayat.lumen.ui.settings.SettingsScreen
import com.hayat.lumen.ui.settings.SettingsSection
import com.hayat.lumen.ui.update.UpdateScreen
import com.hayat.lumen.data.db.Poster
import com.hayat.lumen.data.db.VodCategoryRow
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.ui.components.Tab
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.ui.vod.MovieDetailScreen
import com.hayat.lumen.ui.vod.MyListScreen
import com.hayat.lumen.ui.vod.SeriesDetailScreen
import com.hayat.lumen.ui.vod.VodBrowseScreen
import com.hayat.lumen.ui.vod.VodCategoryScreen
import com.hayat.lumen.ui.vod.VodPlayerScreen
import com.hayat.lumen.ui.vod.VodSearchScreen
import com.hayat.lumen.ui.theme.LumenMotion

/** Navigation destinations. The back stack is just a list of these. */
sealed interface Route
data object AddSourceRoute : Route
data object HomeRoute : Route
data object LiveRoute : Route
/** [inFavourites]: Up/Down zaps through favourites instead of the channel's group. */
data class PlayerRoute(val channelId: Long, val inFavourites: Boolean = false) : Route
/** The TV guide grid. */
data object GuideRoute : Route
/** Settings, opened on [section] (Live's Categories button opens it on Live categories). */
data class SettingsRoute(val section: SettingsSection = SettingsSection.PLAYLISTS) : Route
/** "Update Lumen": install a newer version from GitHub Releases. */
data object UpdateRoute : Route
/** The Movies and Series tabs. They sit right above Home in the back stack, so Back returns to Live TV. */
data object MoviesTabRoute : Route
data object SeriesTabRoute : Route
data object MyListTabRoute : Route
/** "See all" for one category. */
data class VodCategoryRoute(val row: VodCategoryRow) : Route
data object VodSearchRoute : Route
data class MovieDetailRoute(val sourceId: Long, val streamId: String) : Route
data class SeriesDetailRoute(val sourceId: Long, val seriesId: String) : Route
/** A film ([VodKind.MOVIE], [itemId] = stream id) or an episode ([VodKind.SERIES], [itemId] = episode id). */
data class VodPlayerRoute(
    val sourceId: Long,
    val kind: VodKind,
    val itemId: String,
    val seriesId: String? = null,
    val startOver: Boolean = false,
) : Route

/**
 * App navigation. Like SwiftUI's NavigationStack(path:), the back stack is a list we
 * own: push = add, pop = remove last. Back pops; Back on the last screen exits.
 */
@Composable
fun LumenRoot(onExit: () -> Unit) {
    val container = LocalAppContainer.current

    // First launch (no playlists yet) opens on "Add a playlist", otherwise on Home (favourites).
    val start by produceState<Route?>(initialValue = null) {
        value = if (container.live.hasSources()) HomeRoute else AddSourceRoute
    }
    val first = start
    if (first == null) {
        Box(Modifier.fillMaxSize().background(LumenColors.Background))
        return
    }

    val backStack = remember { mutableStateListOf(first) }
    val fade: () -> ContentTransform = { fadeIn(LumenMotion.focus()) togetherWith fadeOut(LumenMotion.focus()) }

    // Tabs swap the screen above Home rather than stacking up, like a tab bar.
    val onTab: (Tab) -> Unit = { tab ->
        if (tab == Tab.SEARCH) {
            backStack.add(VodSearchRoute)
        } else if (tab == Tab.SETTINGS) {
            // Opens on Updates while one is waiting: that's what the blue dot points at.
            val section = if (container.updates.available.value != null) SettingsSection.UPDATES else SettingsSection.PLAYLISTS
            backStack.add(SettingsRoute(section))
        } else {
            backStack.removeAll { it == MoviesTabRoute || it == SeriesTabRoute || it == MyListTabRoute }
            when (tab) {
                Tab.MOVIES -> backStack.add(MoviesTabRoute)
                Tab.SERIES -> backStack.add(SeriesTabRoute)
                Tab.MY_LIST -> backStack.add(MyListTabRoute)
                else -> Unit
            }
        }
    }
    val openPoster: (Poster) -> Unit = { p ->
        backStack.add(
            if (p.kind == VodKind.MOVIE) MovieDetailRoute(p.sourceId, p.itemId) else SeriesDetailRoute(p.sourceId, p.itemId),
        )
    }

    NavDisplay(
        backStack = backStack,
        modifier = Modifier.background(LumenColors.Background),
        onBack = { if (backStack.size > 1) backStack.removeAt(backStack.lastIndex) else onExit() },
        entryDecorators = listOf(
            // Keeps each screen's remembered UI state (scroll positions) while it's in the stack…
            rememberSaveableStateHolderNavEntryDecorator(),
            // …and gives each screen its own ViewModels, cleared when it's popped.
            rememberViewModelStoreNavEntryDecorator(),
        ),
        transitionSpec = { fade() },
        popTransitionSpec = { fade() },
        predictivePopTransitionSpec = { fade() },
        entryProvider = entryProvider {
            entry<AddSourceRoute> {
                AddSourceScreen(onAdded = {
                    container.epg.updateStaleInBackground() // load the new playlist's guide
                    container.vod.refreshStaleInBackground() // and its films and series
                    if (backStack.size > 1) {
                        // Added from Settings: back to the list, which now shows it.
                        backStack.removeAt(backStack.lastIndex)
                    } else {
                        // First playlist: replace "Add" with Home, then open Live on top (no favourites yet).
                        // Back from Live goes to Home; Back from Home exits.
                        backStack.add(HomeRoute)
                        backStack.removeAll { it != HomeRoute }
                        backStack.add(LiveRoute)
                    }
                })
            }
            entry<HomeRoute> {
                HomeScreen(
                    onPlay = { backStack.add(PlayerRoute(it, inFavourites = true)) },
                    onBrowse = { backStack.add(LiveRoute) },
                    onOpenGuide = { backStack.add(GuideRoute) },
                    onTab = onTab,
                )
            }
            entry<LiveRoute> {
                LiveScreen(
                    onPlay = { backStack.add(PlayerRoute(it)) },
                    onOpenGuide = { backStack.add(GuideRoute) },
                    onManageCategories = { backStack.add(SettingsRoute(SettingsSection.LIVE_CATEGORIES)) },
                )
            }
            entry<GuideRoute> {
                GuideScreen(
                    onPlay = { id, inFavourites -> backStack.add(PlayerRoute(id, inFavourites)) },
                    onOpenSettings = { backStack.add(SettingsRoute(SettingsSection.GUIDE)) },
                )
            }
            entry<PlayerRoute> { route ->
                PlayerScreen(channelId = route.channelId, inFavourites = route.inFavourites)
            }
            entry<SettingsRoute> { route ->
                SettingsScreen(
                    initial = route.section,
                    onAddPlaylist = { backStack.add(AddSourceRoute) },
                    onNoPlaylists = {
                        // Nothing left to watch: start over on "Add a playlist".
                        backStack.add(AddSourceRoute)
                        backStack.removeAll { it != AddSourceRoute }
                    },
                    onOpenUpdate = { backStack.add(UpdateRoute) },
                )
            }
            entry<UpdateRoute> {
                UpdateScreen()
            }
            entry<MoviesTabRoute> {
                VodBrowseScreen(
                    kind = VodKind.MOVIE,
                    onTab = onTab,
                    onOpen = openPoster,
                    onSeeAll = { backStack.add(VodCategoryRoute(it)) },
                    onSearch = { backStack.add(VodSearchRoute) },
                )
            }
            entry<MyListTabRoute> {
                MyListScreen(onTab = onTab, onOpen = openPoster, onSearch = { backStack.add(VodSearchRoute) })
            }
            entry<SeriesTabRoute> {
                VodBrowseScreen(
                    kind = VodKind.SERIES,
                    onTab = onTab,
                    onOpen = openPoster,
                    onSeeAll = { backStack.add(VodCategoryRoute(it)) },
                    onSearch = { backStack.add(VodSearchRoute) },
                )
            }
            entry<VodCategoryRoute> { route ->
                VodCategoryScreen(
                    row = route.row,
                    onOpen = openPoster,
                    onHidden = { backStack.removeAt(backStack.lastIndex) },
                )
            }
            entry<VodSearchRoute> {
                VodSearchScreen(onOpen = openPoster)
            }
            entry<MovieDetailRoute> { route ->
                MovieDetailScreen(route.sourceId, route.streamId, onPlay = { startOver ->
                    backStack.add(VodPlayerRoute(route.sourceId, VodKind.MOVIE, route.streamId, startOver = startOver))
                })
            }
            entry<SeriesDetailRoute> { route ->
                SeriesDetailScreen(route.sourceId, route.seriesId, onPlay = { episodeId ->
                    backStack.add(VodPlayerRoute(route.sourceId, VodKind.SERIES, episodeId, seriesId = route.seriesId))
                })
            }
            entry<VodPlayerRoute> { route ->
                VodPlayerScreen(route.sourceId, route.kind, route.itemId, route.seriesId, route.startOver)
            }
        },
    )
}
