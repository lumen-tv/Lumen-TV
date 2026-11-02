package com.hayat.lumen.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.hayat.lumen.data.epg.Programme
import com.hayat.lumen.ui.components.ChannelLogo
import com.hayat.lumen.ui.components.QualityTag
import com.hayat.lumen.ui.components.dayName
import com.hayat.lumen.ui.components.formatDuration
import com.hayat.lumen.ui.components.formatTime
import com.hayat.lumen.ui.components.glass
import com.hayat.lumen.ui.components.timeRange
import com.hayat.lumen.ui.components.LoadingLine
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.ui.theme.SafeArea
import com.hayat.lumen.util.ChannelNames

/** Which programme the guide strip selects. */
object GuidePick {
    /**
     * The programme on at [time], else the first one after it, else the last; -1 when there are none.
     * Keeps the strip at the same time of day while Up/Down moves between channels.
     */
    fun index(programmes: List<Programme>, time: Long): Int {
        if (programmes.isEmpty()) return -1
        programmes.indexOfFirst { time >= it.start && time < it.stop }.takeIf { it >= 0 }?.let { return it }
        programmes.indexOfFirst { it.start >= time }.takeIf { it >= 0 }?.let { return it }
        return programmes.lastIndex
    }
}

/**
 * The guide inside the player: a glass strip over the bottom of the video with one channel's
 * programmes from now on. The video keeps playing behind it; the player handles the keys.
 */
@Composable
fun GuideStrip(browsed: Browsed, schedule: List<Programme>?, selected: Int, now: Long) {
    val channel = browsed.channel
    Box(
        Modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f))))
            .padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical)
            .padding(top = 96.dp),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                // Nearly solid: text over moving video has to stay easy to read.
                .glass(RoundedCornerShape(24.dp), fill = LumenColors.Background.copy(alpha = 0.92f))
                .padding(horizontal = 20.dp, vertical = 14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                ChannelLogo(channel.name, channel.logoUrl, size = 44.dp)
                val name = remember(channel.name) { ChannelNames.display(channel.name) }
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        channel.number?.let {
                            Text(it.toString(), style = MaterialTheme.typography.titleMedium, color = LumenColors.TextSecondary)
                        }
                        Text(
                            name.title,
                            style = MaterialTheme.typography.titleMedium,
                            color = LumenColors.TextPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        name.tags.forEach { QualityTag(it) }
                    }
                    Text(
                        if (browsed.isTuned) "Watching now" else "Press OK to watch",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (browsed.isTuned) LumenColors.TextSecondary else LumenColors.TextPrimary,
                    )
                }
                // The channels Up and Down lead to, so it's clear the strip can move.
                Column(horizontalAlignment = Alignment.End, modifier = Modifier.widthIn(max = 260.dp)) {
                    browsed.previous?.let { Neighbour("▲", it.name) }
                    browsed.next?.let { Neighbour("▼", it.name) }
                }
            }
            Spacer(Modifier.height(12.dp))
            when {
                schedule == null -> Box(Modifier.fillMaxWidth().height(ProgrammesHeight), contentAlignment = Alignment.CenterStart) {
                    LoadingLine(maxWidth = 240.dp)
                }
                schedule.isEmpty() -> Message("No guide info for this channel")
                else -> Programmes(schedule, selected, now, channelKey = channel.id)
            }
        }
    }
}

@Composable
private fun Neighbour(arrow: String, name: String) {
    Text(
        "$arrow  ${ChannelNames.display(name).title}",
        style = MaterialTheme.typography.labelMedium,
        color = LumenColors.TextSecondary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun Message(text: String) {
    // Same height as the programme cards and details, so the strip doesn't jump as the guide loads.
    Box(Modifier.fillMaxWidth().height(ProgrammesHeight), contentAlignment = Alignment.CenterStart) {
        Text(text, style = MaterialTheme.typography.bodyLarge, color = LumenColors.TextSecondary)
    }
}

@Composable
private fun Programmes(schedule: List<Programme>, selected: Int, now: Long, channelKey: Long) {
    val row = rememberLazyListState()
    // A new channel jumps straight to the selection; moving along the same channel slides.
    LaunchedEffect(channelKey) { row.scrollToItem((selected - 1).coerceAtLeast(0)) }
    LaunchedEffect(selected) { row.animateScrollToItem((selected - 1).coerceAtLeast(0)) }

    Column(Modifier.heightIn(min = ProgrammesHeight)) {
        // Not focusable: the player's key handler moves the selection (like the guide grid).
        LazyRow(state = row, userScrollEnabled = false, horizontalArrangement = Arrangement.spacedBy(40.dp)) {
            itemsIndexed(schedule) { index, programme ->
                TextProgramme(programme, selected = index == selected, now = now)
            }
        }
        val shown = schedule.getOrNull(selected) ?: return@Column
        Spacer(Modifier.height(10.dp))
        Text(
            buildString {
                append(shown.title).append("  ·  ")
                dayName(shown.start, now)?.let { append(it).append(' ') }
                append(shown.timeRange()).append("  ·  ")
                if (now >= shown.start) append(formatDuration(shown.stop - now)).append(" left")
                else append(formatDuration(shown.stop - shown.start))
            },
            style = MaterialTheme.typography.bodySmall,
            color = LumenColors.TextSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            shown.description?.takeIf { it.isNotBlank() } ?: "No description",
            style = MaterialTheme.typography.bodyMedium,
            color = LumenColors.TextPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private fun Programme.startLabel(now: Long): String =
    if (now >= start && now < stop) "Now" else listOfNotNull(dayName(start, now), formatTime(start)).joinToString(" ")

/**
 * One programme: its time and title, no box (a box would look like a button). The selected one is
 * bright with a short white line under it; the rest are dimmed.
 */
@Composable
private fun TextProgramme(programme: Programme, selected: Boolean, now: Long) {
    val onNow = now >= programme.start && now < programme.stop
    Column(Modifier.widthIn(max = 300.dp).height(SegmentHeight), verticalArrangement = Arrangement.Center) {
        Text(
            programme.startLabel(now),
            style = MaterialTheme.typography.labelSmall,
            color = if (onNow) LumenColors.Accent else LumenColors.TextSecondary,
        )
        Text(
            programme.title,
            style = MaterialTheme.typography.titleSmall,
            color = if (selected) LumenColors.TextPrimary else LumenColors.TextSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(4.dp))
        Box(
            Modifier
                .width(28.dp)
                .height(3.dp)
                .background(if (selected) Color.White else Color.Transparent, RoundedCornerShape(2.dp)),
        )
    }
}

private val SegmentHeight = 52.dp
private val ProgrammesHeight = 112.dp
