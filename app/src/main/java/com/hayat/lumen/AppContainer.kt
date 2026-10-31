package com.hayat.lumen

import android.content.Context
import androidx.compose.runtime.staticCompositionLocalOf
import coil3.ImageLoader
import coil3.memory.MemoryCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import com.hayat.lumen.data.LiveRepository
import com.hayat.lumen.data.db.LumenDatabase
import com.hayat.lumen.data.epg.EpgRepository
import com.hayat.lumen.data.ratings.OmdbClient
import com.hayat.lumen.data.skip.SkipTimesClient
import com.hayat.lumen.data.settings.Preferences
import com.hayat.lumen.data.update.UpdateRepository
import com.hayat.lumen.data.vod.VodRepository
import com.hayat.lumen.playback.PlayerHolder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * Hand-rolled dependency injection: every long-lived object is created once here
 * and passed to whoever needs it. One instance lives on [LumenApp].
 */
class AppContainer(context: Context) {
    private val appContext = context.applicationContext

    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followSslRedirects(true)
        // Some IPTV servers reject OkHttp's default user agent.
        .addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().header("User-Agent", USER_AGENT).build())
        }
        .build()

    /** For work that should finish even if the screen that started it closes (guide downloads). */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val db: LumenDatabase = LumenDatabase.create(appContext)
    val live = LiveRepository(db, http)
    val epg = EpgRepository(db, http, appScope)
    val vod = VodRepository(db, http, appScope)
    val player = PlayerHolder(appContext, http)
    val updates = UpdateRepository(appContext, http, appScope)
    val prefs = Preferences(appContext)
    val omdb = OmdbClient(http)
    val skipTimes = SkipTimesClient(http)

    /** Loads channel logos through [http] (same user agent). Memory cache kept small for the 2 GB TV. */
    val images: ImageLoader = ImageLoader.Builder(appContext)
        .components { add(OkHttpNetworkFetcherFactory(callFactory = { http })) }
        .memoryCache { MemoryCache.Builder().maxSizePercent(appContext, 0.10).build() }
        .crossfade(true)
        .build()

    /** The channel currently/last playing, so Live can put focus back on it. In-memory for now. */
    val lastChannelId = MutableStateFlow<Long?>(null)

    init {
        // Guides go stale within a day; refresh any older than 12 hours in the background.
        epg.updateStaleInBackground()
        // Film and series lists change slowly; reload them once a day.
        vod.refreshStaleInBackground()
        // Is there a newer Lumen on GitHub? (Home offers it.)
        updates.checkInBackground()
    }

    private companion object {
        const val USER_AGENT = "Lumen/0.1 (Android TV)"
    }
}

/**
 * Makes the container reachable from any composable, like a SwiftUI
 * `.environment(...)` value set once at the root.
 */
val LocalAppContainer = staticCompositionLocalOf<AppContainer> { error("AppContainer not provided") }
