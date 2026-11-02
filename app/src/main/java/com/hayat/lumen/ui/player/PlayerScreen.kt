package com.hayat.lumen.ui.player

import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.compose.ContentFrame
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.data.epg.NowNext
import com.hayat.lumen.playback.PlayerHolder
import com.hayat.lumen.ui.components.BufferingLine
import com.hayat.lumen.ui.components.ChannelLogo
import com.hayat.lumen.ui.components.PlaybackLoading
import com.hayat.lumen.ui.components.rememberChannelColour
import com.hayat.lumen.ui.components.QualityTag
import com.hayat.lumen.ui.components.ProgrammeProgress
import com.hayat.lumen.ui.components.formatTime
import com.hayat.lumen.ui.components.timeRange
import com.hayat.lumen.ui.components.glass
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.util.ChannelNames
import com.hayat.lumen.ui.theme.LumenMotion
import com.hayat.lumen.ui.theme.SafeArea
import kotlinx.coroutines.delay

private enum class Status { LOADING, PLAYING, FAILED }

/**
 * Full-screen live player.
 * Up/Down: previous/next channel in the group (or in favourites, when opened from Home), with a short info overlay ·
 * Back: hide overlay, then leave. OK or Right opens the guide strip: Left/Right = programmes, Up/Down = other channels' guides (the stream
 * stays), OK = watch that channel, Back = close.
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(channelId: Long, inFavourites: Boolean) {
    val container = LocalAppContainer.current
    val vm = viewModel { PlayerViewModel(container.live, container.epg, container.lastChannelId, channelId, inFavourites) }
    val tuned by vm.tuned.collectAsStateWithLifecycle()
    val nowNext by vm.nowNext.collectAsStateWithLifecycle()
    val browsed by vm.browsed.collectAsStateWithLifecycle()
    val schedule by vm.schedule.collectAsStateWithLifecycle()

    var player by remember { mutableStateOf<ExoPlayer?>(null) }
    var status by remember { mutableStateOf(Status.LOADING) }
    /** The tuned channel's picture has appeared: before that the loading screen shows, after it only the thin line. */
    var picture by remember { mutableStateOf(false) }
    var overlay by remember { mutableStateOf(true) }
    var interaction by remember { mutableIntStateOf(0) } // bumps restart the overlay's hide timer
    var retry by remember { mutableIntStateOf(0) }
    val keys = remember { FocusRequester() }

    // The guide strip's selection, and the time it points at: moving to another channel's guide
    // selects what's on there at that time (like Up/Down in the guide grid).
    val guideOpen = browsed != null
    var selected by remember { mutableIntStateOf(0) }
    var anchor by remember { mutableLongStateOf(0L) }
    var guideInteraction by remember { mutableIntStateOf(0) }

    fun showOverlay() {
        overlay = true
        interaction++
    }

    fun select(index: Int) {
        val programmes = schedule ?: return
        val programme = programmes.getOrNull(index) ?: return
        selected = index
        anchor = maxOf(programme.start, System.currentTimeMillis())
    }

    // Acquire the shared player while this screen is visible; stop it when it isn't.
    // (MainActivity releases it fully when the app goes to the background.)
    // `owner` tells the holder who's asking, so Home's preview can't stop us during the fade.
    val owner = remember { Any() }
    LifecycleStartEffect(Unit) {
        val p = container.player.acquire(owner)
        p.volume = 1f // Home's preview plays muted
        player = p
        onStopOrDispose {
            container.player.stop(owner)
            player = null
        }
    }

    // Track playback state for the overlay. Recovers by itself from the common
    // live-HLS hiccup of falling behind the live window.
    DisposableEffect(player) {
        val p = player ?: return@DisposableEffect onDispose { }
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_READY) status = Status.PLAYING
                if (state == Player.STATE_BUFFERING && status != Status.FAILED) status = Status.LOADING
            }

            override fun onRenderedFirstFrame() {
                picture = true
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                // A radio station has no picture to wait for.
                if (isPlaying && !p.currentTracks.isTypeSelected(C.TRACK_TYPE_VIDEO)) picture = true
            }

            override fun onPlayerError(error: PlaybackException) {
                if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                    p.seekToDefaultPosition()
                    p.prepare()
                } else {
                    status = Status.FAILED
                    overlay = true
                }
            }
        }
        p.addListener(listener)
        onDispose { p.removeListener(listener) }
    }

    // Tune. Zapping quickly through channels only opens the one you stop on:
    // many providers allow a single connection, and every open stream counts.
    LaunchedEffect(player, tuned?.channel?.id, retry) {
        val p = player ?: return@LaunchedEffect
        val channel = tuned?.channel ?: return@LaunchedEffect
        // Opened from Home while its preview plays this channel: keep the stream, no re-buffer.
        if (retry == 0 && p.currentMediaItem?.localConfiguration?.uri?.toString() == channel.streamUrl) {
            if (p.playbackState == Player.STATE_READY) {
                status = Status.PLAYING
                picture = true
            }
            p.playWhenReady = true
            return@LaunchedEffect
        }
        val firstTune = p.currentMediaItem == null
        p.stop()
        status = Status.LOADING
        picture = false
        if (!firstTune) delay(ZAP_DEBOUNCE_MS)
        p.setMediaItem(PlayerHolder.mediaItem(channel.streamUrl))
        p.prepare()
        p.playWhenReady = true
    }

    // Auto-hide the overlay a few seconds after the last interaction, once video is playing.
    LaunchedEffect(overlay, interaction, status) {
        if (overlay && status == Status.PLAYING) {
            delay(OVERLAY_TIMEOUT_MS)
            overlay = false
        }
    }

    LaunchedEffect(schedule) {
        schedule?.let { selected = GuidePick.index(it, maxOf(anchor, System.currentTimeMillis())).coerceAtLeast(0) }
    }

    // The strip closes by itself after a while without keys, like the info overlay.
    LaunchedEffect(guideOpen, guideInteraction) {
        if (guideOpen) {
            delay(GUIDE_TIMEOUT_MS)
            vm.closeGuide()
        }
    }

    // TVs dim to a screensaver after inactivity; not while watching.
    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    // Until the picture appears the channel's loading screen covers everything; the info overlay waits.
    val loadingScreen = !picture && status != Status.FAILED

    // Back hides the overlay first; with it hidden, Back falls through to navigation.
    BackHandler(enabled = overlay && !loadingScreen) { overlay = false }
    // Declared later, so it wins while both are enabled (Compose asks the newest BackHandler first).
    BackHandler(enabled = guideOpen) { vm.closeGuide() }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(keys)
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                if (guideOpen) {
                    guideInteraction++
                    return@onKeyEvent when (event.key) {
                        Key.DirectionLeft -> { select(selected - 1); true }
                        Key.DirectionRight -> { select(selected + 1); true }
                        Key.DirectionUp, Key.ChannelDown -> { vm.browse(-1); true }
                        Key.DirectionDown, Key.ChannelUp -> { vm.browse(+1); true }
                        Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                            if (event.nativeKeyEvent.repeatCount == 0) {
                                val switching = browsed?.isTuned == false
                                vm.watchBrowsed()
                                if (switching) showOverlay()
                            }
                            true
                        }
                        else -> false
                    }
                }
                when (event.key) {
                    Key.DirectionRight -> {
                        overlay = false
                        anchor = System.currentTimeMillis()
                        vm.openGuide()
                        guideInteraction++
                        true
                    }
                    Key.DirectionUp, Key.ChannelDown -> { vm.step(-1); showOverlay(); true }
                    Key.DirectionDown, Key.ChannelUp -> { vm.step(+1); showOverlay(); true }
                    Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                        if (event.nativeKeyEvent.repeatCount == 0) {
                            if (status == Status.FAILED) {
                                retry++
                                showOverlay()
                            } else {
                                // OK opens the guide strip, which shows the channel and what's on too.
                                overlay = false
                                anchor = System.currentTimeMillis()
                                vm.openGuide()
                                guideInteraction++
                            }
                        }
                        true
                    }
                    else -> false
                }
            }
            .focusable(),
    ) {
        player?.let { p ->
            ContentFrame(player = p, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }

        // The channel's colour, name and what's on, big in the middle, until its picture appears
        // (as on the iPhone). A hiccup later shows only the thin line along the bottom.
        AnimatedVisibility(
            visible = loadingScreen,
            enter = fadeIn(tween(0)),
            exit = fadeOut(tween(LOADING_FADE_MS)),
        ) {
            // Keeps the channel it was showing while it fades out.
            var shown by remember { mutableStateOf(tuned) }
            var shownNow by remember { mutableStateOf(nowNext) }
            if (loadingScreen) { shown = tuned; shownNow = nowNext }
            shown?.let { t ->
                val name = remember(t.channel.name) { ChannelNames.display(t.channel.name).title }
                PlaybackLoading(
                    artUrl = null,
                    heading = name,
                    colour = rememberChannelColour(t.channel.name, t.channel.logoUrl),
                    detail = shownNow?.now?.title,
                )
            }
        }
        if (picture && status == Status.LOADING) {
            BufferingLine(Modifier.align(Alignment.BottomCenter))
        }

        AnimatedVisibility(
            visible = overlay && !loadingScreen,
            enter = fadeIn(LumenMotion.focus()),
            exit = fadeOut(LumenMotion.focus()),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            tuned?.let { InfoOverlay(it, nowNext, status) }
        }

        AnimatedVisibility(
            visible = guideOpen,
            enter = fadeIn(LumenMotion.focus()) + slideInVertically(LumenMotion.focus()) { it / 4 },
            exit = fadeOut(LumenMotion.focus()),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            // Keeps showing the last channel while the strip fades out.
            var last by remember { mutableStateOf(browsed) }
            var lastSchedule by remember { mutableStateOf(schedule) }
            browsed?.let { last = it; lastSchedule = schedule }
            last?.let { GuideStrip(it, lastSchedule, selected, System.currentTimeMillis()) }
        }
    }

    LaunchedEffect(Unit) { keys.requestFocus() }
}

@Composable
private fun InfoOverlay(tuned: Tuned, nowNext: NowNext?, status: Status) {
    val channel = tuned.channel
    Box(
        Modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.5f))))
            .padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical)
            .padding(top = 96.dp),
    ) {
        // A dark frosted panel: over video a light one would wash out.
        Row(
            Modifier
                .fillMaxWidth()
                .glass(RoundedCornerShape(28.dp), fill = LumenColors.Background.copy(alpha = 0.9f))
                .padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            ChannelLogo(channel.name, channel.logoUrl, size = 72.dp)
            val name = remember(channel.name) { ChannelNames.display(channel.name) }
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    channel.number?.let {
                        Text(it.toString(), style = MaterialTheme.typography.headlineMedium, color = LumenColors.TextSecondary)
                    }
                    Text(
                        name.title,
                        style = MaterialTheme.typography.headlineMedium,
                        color = LumenColors.TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    name.tags.forEach { QualityTag(it) }
                }
                val now = nowNext?.now
                if (now == null) {
                    Text(
                        channel.groupLabel,
                        style = MaterialTheme.typography.bodyLarge,
                        color = LumenColors.TextSecondary,
                        maxLines = 1,
                    )
                } else {
                    Text(
                        "${now.title}   ${now.timeRange()}",
                        style = MaterialTheme.typography.bodyLarge,
                        color = LumenColors.TextSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    ProgrammeProgress(
                        now.progress(System.currentTimeMillis()),
                        color = LumenColors.TextSecondary,
                        modifier = Modifier.padding(vertical = 6.dp).widthIn(max = 480.dp),
                    )
                }
                nowNext?.next?.let { next ->
                    Text(
                        "Next  ${formatTime(next.start)}  ${next.title}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = LumenColors.TextTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    when (status) {
                        Status.LOADING -> ""
                        Status.PLAYING -> ""
                        Status.FAILED -> "Can't play this channel right now"
                    },
                    style = MaterialTheme.typography.bodyLarge,
                    color = LumenColors.TextPrimary,
                )
                Text(
                    if (status == Status.FAILED) "Press OK to try again" else "${tuned.position} of ${tuned.total}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = LumenColors.TextTertiary,
                )
            }
        }
    }
}

private const val ZAP_DEBOUNCE_MS = 350L
private const val LOADING_FADE_MS = 400
private const val OVERLAY_TIMEOUT_MS = 5_000L
private const val GUIDE_TIMEOUT_MS = 12_000L
