package com.hayat.lumen.data.settings

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Small app settings that aren't tied to a playlist, in SharedPreferences (Android's
 * UserDefaults). Backups are off, so nothing here leaves the TV.
 */
class Preferences(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private val _omdbKey = MutableStateFlow(prefs.getString(KEY_OMDB, null))
    /** The user's own OMDb key, for IMDb and Rotten Tomatoes scores. Never logged. */
    val omdbKey: StateFlow<String?> = _omdbKey.asStateFlow()

    fun setOmdbKey(key: String?) {
        val clean = key?.trim()?.takeIf { it.isNotEmpty() }
        prefs.edit { if (clean == null) remove(KEY_OMDB) else putString(KEY_OMDB, clean) }
        _omdbKey.value = clean
    }

    private val seasons = context.getSharedPreferences("series_seasons", Context.MODE_PRIVATE)

    /** The season last picked on a series' page, so it opens there next time. */
    fun lastSeason(sourceId: Long, seriesId: String): Int? =
        seasons.getInt("$sourceId/$seriesId", -1).takeIf { it >= 0 }

    fun setLastSeason(sourceId: Long, seriesId: String, season: Int) {
        seasons.edit { putInt("$sourceId/$seriesId", season) }
    }

    private companion object {
        const val KEY_OMDB = "omdb_key"
    }
}
