package com.hayat.lumen.ui.vod

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hayat.lumen.data.db.Poster
import com.hayat.lumen.data.db.VodCategoryRow
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.vod.VodRepository
import com.hayat.lumen.data.vod.VodSync
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.transformLatest
import kotlinx.coroutines.launch

/** The Movies or Series tab: its rows, and the hero for whichever poster has focus. */
@OptIn(ExperimentalCoroutinesApi::class)
class VodBrowseViewModel(private val vod: VodRepository, val kind: VodKind) : ViewModel() {

    /** null until the first query returns, so the tab doesn't flash its empty state. */
    val categories: StateFlow<List<VodCategoryRow>?> =
        vod.categories(kind).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)
    val continueWatching: StateFlow<List<Poster>> =
        vod.continueWatching(kind).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val hiddenCount: StateFlow<Int> =
        vod.hiddenCount(kind).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), 0)
    val sync: StateFlow<VodSync> = vod.sync

    private val focused = MutableStateFlow<Poster?>(null)

    /** Quick info at once; the full info (plot, backdrop) once focus has rested for a moment. */
    val hero: StateFlow<HeroInfo?> = focused
        .transformLatest { poster ->
            if (poster == null) return@transformLatest
            emit(poster.quickHero())
            delay(HERO_DELAY_MS)
            emit(vod.hero(poster))
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun focus(poster: Poster) {
        focused.value = poster
    }

    /** A row's posters. The top row's first one fills the hero until something has focus. */
    suspend fun posters(row: VodCategoryRow, fillsHero: Boolean = false): List<Poster> =
        vod.postersIn(row, ROW_LIMIT).also { posters ->
            if (fillsHero && focused.value == null) posters.firstOrNull()?.let(::focus)
        }

    fun toggleMyList(poster: Poster, onDone: (Boolean) -> Unit) {
        viewModelScope.launch { onDone(vod.toggleMyList(poster.sourceId, poster.kind, poster.itemId)) }
    }

    /** The wide Continue watching card's picture. */
    suspend fun backdrop(poster: Poster): String? = vod.hero(poster).backdropUrl

    fun removeFromContinue(poster: Poster) {
        viewModelScope.launch { vod.removeFromContinue(poster) }
    }

    fun hide(row: VodCategoryRow) {
        viewModelScope.launch { vod.hideCategory(row) }
    }

    fun showHidden() {
        viewModelScope.launch { vod.showAllCategories(kind) }
    }

    companion object {
        /** Posters per row; "See all" opens the rest. */
        const val ROW_LIMIT = 30
        private const val HERO_DELAY_MS = 450L
    }
}

/** The whole category, for "See all". */
@OptIn(ExperimentalCoroutinesApi::class)
class VodCategoryViewModel(private val vod: VodRepository, row: VodCategoryRow) : ViewModel() {
    val posters: StateFlow<List<Poster>?> = MutableStateFlow(row)
        .mapLatest { vod.postersIn(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun toggleMyList(poster: Poster, onDone: (Boolean) -> Unit) {
        viewModelScope.launch { onDone(vod.toggleMyList(poster.sourceId, poster.kind, poster.itemId)) }
    }

    fun hide(row: VodCategoryRow) {
        viewModelScope.launch { vod.hideCategory(row) }
    }
}
