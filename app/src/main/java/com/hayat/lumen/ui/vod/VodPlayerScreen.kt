package com.hayat.lumen.ui.vod

import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.SubtitleView
import androidx.media3.ui.compose.ContentFrame
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.hayat.lumen.LocalAppContainer
import androidx.compose.foundation.layout.size
import androidx.compose.ui.res.painterResource
import androidx.tv.material3.Icon
import com.hayat.lumen.R
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.skip.SkipOffer
import com.hayat.lumen.data.skip.SkipPick
import com.hayat.lumen.data.skip.SkipSegment
import com.hayat.lumen.playback.PlayerHolder
import com.hayat.lumen.ui.components.LumenListItem
import com.hayat.lumen.ui.components.ProgrammeProgress
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.ui.theme.LumenMotion
import com.hayat.lumen.ui.theme.SafeArea
import kotlinx.coroutines.delay
import java.util.Locale

internal enum class VodStatus { LOADING, READY, ENDED, FAILED }

/**
 * Full-screen film/episode player.
 * OK or Play/Pause: pause and resume · Left/Right: back/forward 10 s; quick taps and holding speed up ([SeekRamp]) ·
 * Down then OK: audio and subtitles · Back: hide the controls, then leave.
 * During an intro or recap (times from [com.hayat.lumen.data.skip.SkipTimesClient]) a "Skip intro" pill shows and OK
 * skips it; in the end credits it says "Next episode". Back hides the pill. Your place is saved as you
 * watch; at the end of an episode the next one starts after a short countdown.
 */
@OptIn(UnstableApi::class)
@Composable
fun VodPlayerScreen(sourceId: Long, kind: VodKind, itemId: String, seriesId: String?, startOver: Boolean) {
    val container = LocalAppContainer.current
    val vm = viewModel { VodPlayerViewModel(container.vod, container.skipTimes, container.omdb, container.prefs, sourceId, kind, itemId, seriesId, startOver) }
    val now by vm.now.collectAsStateWithLifecycle()
    val error by vm.error.collectAsStateWithLifecycle()
    val skips by vm.skips.collectAsStateWithLifecycle()

    var player by remember { mutableStateOf<ExoPlayer?>(null) }
    var status by remember { mutableStateOf(VodStatus.LOADING) }
    var playing by remember { mutableStateOf(false) }
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(0L) }
    var controls by remember { mutableStateOf(true) }
    var interaction by remember { mutableIntStateOf(0) }
    /** Where Left/Right is taking us; applied once the keys go quiet, so holding them doesn't re-buffer each step. */
    var seekTarget by remember { mutableStateOf<Long?>(null) }
    /** Where the current seek started, for the "+12:30" shown while seeking. */
    var seekFrom by remember { mutableLongStateOf(0L) }
    val seekRamp = remember { SeekRamp() }
    var panel by remember { mutableStateOf(false) }
    var buttonFocused by remember { mutableStateOf(false) }
    var tracks by remember { mutableStateOf(Tracks.EMPTY) }
    var cues by remember { mutableStateOf<List<Cue>>(emptyList()) }
    var countdown by remember { mutableStateOf<Int?>(null) }
    val keys = remember { FocusRequester() }
    /** The segment whose pill Back put away, so it stays away until the next one. */
    var skipDismissed by remember { mutableStateOf<Long?>(null) }

    fun showControls() {
        controls = true
        interaction++
    }

    // Same shared player as live TV. Saves your place when leaving (Back, Home button, screen off).
    val owner = remember { Any() }
    LifecycleStartEffect(Unit) {
        val p = container.player.acquire(owner)
        p.volume = 1f
        player = p
        onStopOrDispose {
            if (p.currentMediaItem != null && p.duration > 0 && status != VodStatus.ENDED) vm.save(p.currentPosition, p.duration)
            container.player.stop(owner)
            player = null
        }
    }

    DisposableEffect(player) {
        val p = player ?: return@DisposableEffect onDispose { }
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_READY -> status = VodStatus.READY
                    Player.STATE_BUFFERING -> if (status != VodStatus.FAILED) status = VodStatus.LOADING
                    Player.STATE_ENDED -> {
                        status = VodStatus.ENDED
                        if (p.duration > 0) vm.save(p.duration, p.duration)
                    }
                    else -> Unit
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                playing = isPlaying
                // Pausing is a natural moment to save.
                if (!isPlaying && p.duration > 0 && p.playbackState == Player.STATE_READY) vm.save(p.currentPosition, p.duration)
            }

            override fun onPlayerError(error: PlaybackException) {
                status = VodStatus.FAILED
                controls = true
            }

            override fun onTracksChanged(newTracks: Tracks) {
                tracks = newTracks
            }

            override fun onCues(cueGroup: CueGroup) {
                cues = cueGroup.cues
            }
        }
        p.addListener(listener)
        onDispose { p.removeListener(listener) }
    }

    // Open the film or episode, at the saved position.
    LaunchedEffect(player, now?.item?.itemId) {
        val p = player ?: return@LaunchedEffect
        val item = now ?: return@LaunchedEffect
        p.stop()
        status = VodStatus.LOADING
        countdown = null
        cues = emptyList()
        skipDismissed = null
        p.setMediaItem(PlayerHolder.mediaItem(item.item.url), item.startMs)
        p.prepare()
        p.playWhenReady = true
        showControls()
    }

    // Position for the progress bar, and a save every so often in case the TV loses power.
    LaunchedEffect(player) {
        val p = player ?: return@LaunchedEffect
        var sinceSave = 0L
        while (true) {
            position = p.currentPosition
            duration = p.duration.takeIf { it > 0 } ?: 0L
            delay(TICK_MS)
            sinceSave += TICK_MS
            if (sinceSave >= SAVE_EVERY_MS && p.isPlaying && duration > 0) {
                vm.save(p.currentPosition, duration)
                sinceSave = 0
            }
        }
    }

    LaunchedEffect(seekTarget) {
        val target = seekTarget ?: return@LaunchedEffect
        delay(SEEK_SETTLE_MS)
        player?.seekTo(target)
        position = target
        seekTarget = null
    }

    LaunchedEffect(controls) { if (!controls) buttonFocused = false }

    LaunchedEffect(controls, interaction, playing, panel) {
        if (controls && playing && !panel) {
            delay(CONTROLS_TIMEOUT_MS)
            controls = false
        }
    }

    // End of an episode: count down, then play the next one.
    LaunchedEffect(status, now?.next?.id) {
        if (status != VodStatus.ENDED || now?.next == null) {
            countdown = null
            return@LaunchedEffect
        }
        for (s in UP_NEXT_SECONDS downTo 1) {
            countdown = s
            delay(1_000)
        }
        vm.playNext()
    }

    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    val offer = SkipPick.at(skips, position, duration, hasNext = now?.next != null)
        ?.takeIf { status == VodStatus.READY && seekTarget == null && !panel && it.segmentStartMs != skipDismissed }

    fun skip(o: SkipOffer) {
        val p = player ?: return
        val target = o.targetMs
        if (target == null) {
            vm.save(p.duration, p.duration) // the credits count as watched
            vm.playNext()
        } else {
            p.seekTo(target)
            position = target
        }
    }

    BackHandler(enabled = panel) { panel = false }
    BackHandler(enabled = offer != null && !panel && !controls) { skipDismissed = offer?.segmentStartMs }
    BackHandler(enabled = !panel && controls && status == VodStatus.READY) { controls = false }

    fun togglePlay() {
        val p = player ?: return
        when (status) {
            VodStatus.FAILED -> {
                status = VodStatus.LOADING
                p.prepare()
                p.playWhenReady = true
            }
            VodStatus.ENDED -> if (now?.next != null) vm.playNext() else {
                p.seekTo(0)
                p.playWhenReady = true
            }
            else -> p.playWhenReady = !p.playWhenReady
        }
        showControls()
    }

    fun seekBy(direction: Int, repeat: Int, eventTime: Long) {
        val p = player ?: return
        if (status == VodStatus.ENDED || duration <= 0) return
        val from = seekTarget ?: p.currentPosition.also { seekFrom = it }
        val step = seekRamp.step(direction, repeat, duration, eventTime)
        seekTarget = (from + step).coerceIn(0L, (duration - 1_000).coerceAtLeast(0))
        showControls()
    }

    val audio = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
    val text = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
    val hasChoices = audio.sumOf { it.length } > 1 || text.isNotEmpty()

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(keys)
            .onKeyEvent { event ->
                if (panel || event.type != KeyEventType.KeyDown) return@onKeyEvent false
                val repeat = event.nativeKeyEvent.repeatCount
                when (event.key) {
                    Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                        if (repeat == 0) {
                            val o = offer
                            if (buttonFocused && controls) {
                                buttonFocused = false
                                panel = true
                            } else if (o != null) {
                                skip(o)
                            } else {
                                togglePlay()
                            }
                        }
                        true
                    }
                    Key.MediaPlayPause, Key.MediaPlay, Key.MediaPause -> {
                        if (repeat == 0) togglePlay()
                        true
                    }
                    Key.DirectionLeft, Key.MediaRewind -> { buttonFocused = false; seekBy(-1, repeat, event.nativeKeyEvent.eventTime); true }
                    Key.DirectionRight, Key.MediaFastForward -> { buttonFocused = false; seekBy(+1, repeat, event.nativeKeyEvent.eventTime); true }
                    Key.DirectionUp -> {
                        // Only the button opens audio and subtitles (Hayat: Up opened it by accident).
                        buttonFocused = false
                        showControls()
                        true
                    }
                    Key.DirectionDown -> {
                        // With the controls up, Down highlights the Audio & Subtitles button.
                        if (controls && hasChoices) buttonFocused = true
                        showControls()
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
        // Subtitles, drawn by Media3's own view (Compose has no subtitle renderer yet).
        AndroidView(
            factory = { SubtitleView(it).apply { setUserDefaultStyle(); setUserDefaultTextSize() } },
            update = { it.setCues(cues) },
            modifier = Modifier.fillMaxSize().padding(bottom = if (controls) 120.dp else 0.dp),
        )

        AnimatedVisibility(
            visible = controls || status != VodStatus.READY || seekTarget != null,
            enter = fadeIn(LumenMotion.focus()),
            exit = fadeOut(LumenMotion.focus()),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            Controls(
                title = now?.title.orEmpty(),
                subtitle = now?.subtitle,
                status = status,
                error = error,
                playing = playing,
                position = seekTarget ?: position,
                duration = duration,
                seeking = seekTarget != null,
                seekDelta = seekTarget?.let { it - seekFrom },
                tracksButton = if (hasChoices) buttonFocused else null,
            )
        }

        // Above the controls when they're up, else in the corner, like the Apple TV app.
        AnimatedVisibility(
            visible = offer != null,
            enter = fadeIn(LumenMotion.focus()),
            exit = fadeOut(LumenMotion.focus()),
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = SafeArea.Horizontal, bottom = if (controls) SKIP_ABOVE_CONTROLS else SafeArea.Vertical + 16.dp),
        ) {
            // Keeps the last label while fading out.
            var label by remember { mutableStateOf("") }
            offer?.let { label = it.label }
            SkipButton(label, highlighted = !buttonFocused)
        }

        val next = now?.nextLabel
        val seconds = countdown
        if (next != null && seconds != null) {
            UpNext(next, seconds, Modifier.align(Alignment.TopEnd).padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical))
        }

        AnimatedVisibility(
            visible = panel,
            enter = fadeIn(LumenMotion.focus()),
            exit = fadeOut(LumenMotion.focus()),
            modifier = Modifier.align(Alignment.CenterEnd),
        ) {
            TracksPanel(
                audio = audio,
                text = text,
                onSelect = { group, index ->
                    val p = player ?: return@TracksPanel
                    p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(group.type, false)
                        .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, index))
                        .build()
                },
                onSubtitlesOff = {
                    val p = player ?: return@TracksPanel
                    p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                        .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                        .build()
                },
                subtitlesOff = player?.trackSelectionParameters?.disabledTrackTypes?.contains(C.TRACK_TYPE_TEXT) == true ||
                    text.none { it.isSelected },
            )
        }
    }

    // Focus goes back to the player when the panel closes, so the keys work again.
    LaunchedEffect(panel) { if (!panel) runCatching { keys.requestFocus() } }
}

@Composable
internal fun Controls(
    title: String,
    subtitle: String?,
    status: VodStatus,
    error: String?,
    playing: Boolean,
    position: Long,
    duration: Long,
    seeking: Boolean,
    seekDelta: Long?,
    /** Null: no audio or subtitle choices, so no button. Else whether the button has the highlight. */
    tracksButton: Boolean?,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.85f))))
            .padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical)
            .padding(top = 96.dp),
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f)) {
                subtitle?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, style = MaterialTheme.typography.titleMedium, color = LumenColors.TextSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(title, style = MaterialTheme.typography.headlineMedium, color = LumenColors.TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            val state = when {
                error != null -> error
                status == VodStatus.FAILED -> "Can't play this right now. Press OK to try again."
                status == VodStatus.LOADING -> "Loading…"
                status == VodStatus.ENDED -> ""
                !playing && !seeking -> "Paused"
                else -> ""
            }
            Text(state, style = MaterialTheme.typography.bodyLarge, color = LumenColors.TextPrimary)
        }
        Spacer(Modifier.height(16.dp))
        if (duration > 0) {
            ProgrammeProgress(position.toFloat() / duration, color = Color.White, height = if (seeking) 8.dp else 5.dp)
            Spacer(Modifier.height(8.dp))
            Row {
                Text(
                    formatPosition(position),
                    style = if (seeking) MaterialTheme.typography.titleLarge else MaterialTheme.typography.bodyMedium,
                    color = LumenColors.TextPrimary,
                )
                Spacer(Modifier.weight(1f))
                // While seeking: how far from where you started ("+12:30"), so you can tell the speed.
                if (seekDelta != null) {
                    Text(
                        (if (seekDelta < 0) "−" else "+") + formatPosition(kotlin.math.abs(seekDelta)),
                        style = MaterialTheme.typography.titleLarge,
                        color = LumenColors.TextPrimary,
                    )
                }
                Spacer(Modifier.weight(1f))
                Text("-${formatPosition((duration - position).coerceAtLeast(0))}", style = MaterialTheme.typography.bodyMedium, color = LumenColors.TextSecondary)
            }
        }
        if (tracksButton != null) {
            Spacer(Modifier.height(14.dp))
            TracksButton(highlighted = tracksButton)
        }
    }
}

/**
 * The Audio and Subtitles button under the progress bar, as in the Apple TV app. Down moves the
 * highlight onto it and OK opens the panel. It isn't a real focusable: the player's key handler owns
 * the D-pad (Left/Right must keep seeking), so it only draws the highlight it's told to.
 */
@Composable
private fun TracksButton(highlighted: Boolean) {
    val bg = if (highlighted) LumenColors.TextPrimary else LumenColors.GlassStrong
    val fg = if (highlighted) LumenColors.Background else LumenColors.TextPrimary
    Row(
        Modifier
            .background(bg, RoundedCornerShape(50))
            .padding(horizontal = 18.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(painterResource(R.drawable.ic_subtitles), contentDescription = null, tint = fg, modifier = Modifier.size(22.dp))
        Text("Audio & Subtitles", style = MaterialTheme.typography.titleSmall, color = fg)
    }
}

/**
 * "Skip intro" / "Skip recap" / "Next episode". Like [TracksButton] it only draws the highlight it's
 * told to; OK reaches it through the player's key handler. White while OK would press it.
 */
@Composable
internal fun SkipButton(label: String, highlighted: Boolean, modifier: Modifier = Modifier) {
    val bg = if (highlighted) LumenColors.TextPrimary else Color.Black.copy(alpha = 0.55f)
    val fg = if (highlighted) LumenColors.Background else LumenColors.TextPrimary
    Row(
        modifier
            .background(bg, RoundedCornerShape(50))
            .padding(horizontal = 26.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(painterResource(R.drawable.ic_skip_next), contentDescription = null, tint = fg, modifier = Modifier.size(26.dp))
        Text(label, style = MaterialTheme.typography.titleMedium, color = fg)
    }
}

@Composable
private fun UpNext(label: String, seconds: Int, modifier: Modifier = Modifier) {
    Column(
        modifier
            .background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(16.dp))
            .padding(horizontal = 24.dp, vertical = 18.dp)
            .width(320.dp),
    ) {
        Text("Up next", style = MaterialTheme.typography.labelLarge, color = LumenColors.TextSecondary)
        Spacer(Modifier.height(4.dp))
        Text(label, style = MaterialTheme.typography.titleLarge, color = LumenColors.TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(8.dp))
        Text("Starts in $seconds s · OK to play now", style = MaterialTheme.typography.bodyMedium, color = LumenColors.TextSecondary)
    }
}

/**
 * Audio and subtitle choices, in a panel on the right like tvOS's info panel. Long lists show the
 * chosen track and the TV's language and English first, with the rest behind "More languages".
 */
@OptIn(UnstableApi::class)
@Composable
internal fun TracksPanel(
    audio: List<Tracks.Group>,
    text: List<Tracks.Group>,
    onSelect: (Tracks.Group, Int) -> Unit,
    onSubtitlesOff: () -> Unit,
    subtitlesOff: Boolean,
) {
    val first = remember { FocusRequester() }
    var audioOpen by remember { mutableStateOf(false) }
    var textOpen by remember { mutableStateOf(false) }
    val preferred = remember { listOfNotNull(iso3(Locale.getDefault().language), "eng").distinct() }

    val audioChoices = audio.flatMap { g -> (0 until g.length).map { g to it } }
    val textChoices = text.flatMap { g -> (0 until g.length).map { g to it } }
    val audioCommon = remember(audioChoices) {
        TrackPicks.common(
            audioChoices.map { (g, i) -> iso3(g.getTrackFormat(i).language) },
            audioChoices.indices.filter { audioChoices[it].let { (g, i) -> g.isTrackSelected(i) } }.toSet(),
            preferred,
        )
    }
    val textCommon = remember(textChoices, subtitlesOff) {
        TrackPicks.common(
            textChoices.map { (g, i) -> iso3(g.getTrackFormat(i).language) },
            if (subtitlesOff) emptySet() else textChoices.indices.filter { textChoices[it].let { (g, i) -> g.isTrackSelected(i) } }.toSet(),
            preferred,
        )
    }
    val audioShown = if (audioOpen || audioCommon == null) audioChoices.indices.toList() else audioCommon
    val textShown = if (textOpen || textCommon == null) textChoices.indices.toList() else textCommon

    LazyColumn(
        Modifier
            .fillMaxHeight()
            .width(360.dp)
            .background(Color(0xF01C1C1E))
            .padding(horizontal = 16.dp, vertical = SafeArea.Vertical),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        if (audioChoices.isNotEmpty()) {
            item { PanelHeader("Audio") }
            items(audioShown, key = { "a$it" }) { index ->
                val (group, i) = audioChoices[index]
                val format = group.getTrackFormat(i)
                TrackRow(
                    label = audioLabel(format.language, format.label, format.channelCount),
                    selected = group.isTrackSelected(i),
                    supported = group.isTrackSupported(i),
                    onClick = { onSelect(group, i) },
                    modifier = if (index == audioShown.first()) Modifier.focusRequester(first) else Modifier,
                )
            }
            if (audioCommon != null) {
                item(key = "audioMore") {
                    MoreRow(open = audioOpen, hidden = audioChoices.size - audioCommon.size, onClick = { audioOpen = !audioOpen })
                }
            }
        }
        item { PanelHeader("Subtitles") }
        item(key = "off") {
            TrackRow(
                label = "Off",
                selected = subtitlesOff,
                supported = true,
                onClick = onSubtitlesOff,
                modifier = if (audioChoices.isEmpty()) Modifier.focusRequester(first) else Modifier,
            )
        }
        items(textShown, key = { "t$it" }) { index ->
            val (group, i) = textChoices[index]
            val format = group.getTrackFormat(i)
            TrackRow(
                label = languageName(format.language, format.label),
                selected = !subtitlesOff && group.isTrackSelected(i),
                supported = group.isTrackSupported(i),
                onClick = { onSelect(group, i) },
            )
        }
        if (textCommon != null) {
            item(key = "textMore") {
                MoreRow(open = textOpen, hidden = textChoices.size - textCommon.size, onClick = { textOpen = !textOpen })
            }
        }
    }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
}

/** The row that opens (or closes) the rest of a long track list. */
@Composable
private fun MoreRow(open: Boolean, hidden: Int, onClick: () -> Unit) {
    LumenListItem(onClick = onClick, minHeight = 44.dp) {
        Text(if (open) "▴" else "▾", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.width(18.dp))
        Text(
            if (open) "Fewer languages" else "More languages ($hidden)",
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
        )
    }
}

/** "en" and "eng" both → "eng", so tracks and the TV's language compare. */
private fun iso3(language: String?): String? =
    language?.takeIf { it.isNotBlank() && it != "und" }?.let { runCatching { Locale.forLanguageTag(it).isO3Language }.getOrNull() ?: it }

@Composable
private fun PanelHeader(text: String) {
    Text(text, style = MaterialTheme.typography.titleMedium, color = LumenColors.TextSecondary, modifier = Modifier.padding(top = 16.dp, bottom = 6.dp, start = 16.dp))
}

@Composable
private fun TrackRow(label: String, selected: Boolean, supported: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    LumenListItem(onClick = onClick, modifier = modifier, minHeight = 44.dp) {
        Text(if (selected) "✓" else "", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.width(18.dp))
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!supported) Text("This TV can't play this one", style = MaterialTheme.typography.bodySmall)
        }
    }
}

private fun languageName(language: String?, label: String?): String {
    val lang = language?.takeIf { it.isNotBlank() && it != "und" }?.let { Locale.forLanguageTag(it).getDisplayLanguage(Locale.getDefault()) }
    return listOfNotNull(lang?.takeIf { it.isNotBlank() }, label?.takeIf { it.isNotBlank() && it != lang }).joinToString(" · ").ifEmpty { "Unknown" }
}

private fun audioLabel(language: String?, label: String?, channels: Int): String {
    val layout = when (channels) {
        1 -> "Mono"
        2 -> "Stereo"
        6 -> "5.1"
        8 -> "7.1"
        else -> null
    }
    return listOfNotNull(languageName(language, label), layout).joinToString(" · ")
}

private const val TICK_MS = 500L
private const val SAVE_EVERY_MS = 15_000L
private const val SEEK_SETTLE_MS = 600L
private const val CONTROLS_TIMEOUT_MS = 5_000L
private const val UP_NEXT_SECONDS = 10
/** Clears the title, progress bar and Audio & Subtitles button. */
private val SKIP_ABOVE_CONTROLS = 210.dp
