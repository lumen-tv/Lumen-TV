package com.hayat.lumen.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.focusGroup
import androidx.compose.runtime.remember
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.R
import com.hayat.lumen.ui.theme.LumenColors
import kotlinx.coroutines.delay
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** [SEARCH] and [SETTINGS] aren't tabs of their own: they open their screen on top. */
enum class Tab(val label: String) { SEARCH("Search"), LIVE("Live TV"), MOVIES("Movies"), SERIES("Series"), MY_LIST("My List"), SETTINGS("Settings") }

/**
 * The top of every main screen, Chillio style: one frosted-glass pill in the middle
 * (search · Live TV · Movies · Series · My List · settings) and the time on the right. [leading] fills
 * the left (a status line, say). The open tab keeps a soft fill; the focused item turns white.
 * The settings gear gets a blue dot while an update is waiting.
 */
@Composable
fun TopTabs(
    selected: Tab,
    onSelect: (Tab) -> Unit,
    modifier: Modifier = Modifier,
    leading: @Composable BoxScope.() -> Unit = {},
) {
    val update by LocalAppContainer.current.updates.available.collectAsStateWithLifecycle()
    val selectedFocus = remember { FocusRequester() }
    Box(modifier.fillMaxWidth()) {
        Box(Modifier.align(Alignment.CenterStart).fillMaxWidth(0.25f), content = leading)
        Row(
            Modifier
                .align(Alignment.Center)
                // Up from the screen lands on the open tab, not on whatever item is nearest (the search icon).
                // SwiftUI's focus engine picks a "preferred" item for you; Compose needs it spelled out like this.
                .focusProperties { onEnter = { selectedFocus.requestFocus() } }
                .focusGroup()
                .glass(RoundedCornerShape(50))
                .padding(6.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Tab.entries.forEach { tab ->
                BarItem(
                    selected = tab == selected,
                    onClick = { if (tab != selected) onSelect(tab) },
                    padding = if (tab.icon != null) PaddingValues(10.dp) else PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    modifier = if (tab == selected) Modifier.focusRequester(selectedFocus) else Modifier,
                ) {
                    val icon = tab.icon
                    if (icon == null) {
                        Text(tab.label, style = MaterialTheme.typography.titleMedium)
                    } else {
                        Box {
                            Icon(painterResource(icon), contentDescription = tab.label, modifier = Modifier.size(22.dp))
                            if (tab == Tab.SETTINGS && update != null) {
                                Box(
                                    Modifier
                                        .align(Alignment.TopEnd)
                                        .offset(x = 3.dp, y = (-3).dp)
                                        .size(9.dp)
                                        .background(LumenColors.Accent, CircleShape),
                                )
                            }
                        }
                    }
                }
            }
        }
        Clock(Modifier.align(Alignment.CenterEnd))
    }
}

private val Tab.icon: Int?
    get() = when (this) {
        Tab.SEARCH -> R.drawable.ic_search
        Tab.SETTINGS -> R.drawable.ic_settings
        else -> null
    }

@Composable
private fun BarItem(
    selected: Boolean,
    onClick: () -> Unit,
    padding: PaddingValues,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) LumenColors.GlassStrong else Color.Transparent,
            contentColor = if (selected) LumenColors.TextPrimary else LumenColors.TextSecondary,
            focusedContainerColor = LumenColors.TextPrimary,
            focusedContentColor = LumenColors.Background,
            pressedContainerColor = LumenColors.TextSecondary,
            pressedContentColor = LumenColors.Background,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.05f),
    ) {
        Box(Modifier.padding(padding)) { content() }
    }
}

/** The time, and the date under it. Ticks over on the minute. */
@Composable
fun Clock(modifier: Modifier = Modifier) {
    val now by produceState(LocalDateTime.now()) {
        while (true) {
            delay(60_000L - System.currentTimeMillis() % 60_000L)
            value = LocalDateTime.now()
        }
    }
    Column(modifier, horizontalAlignment = Alignment.End) {
        Text(now.format(TimeFormat), style = MaterialTheme.typography.titleLarge, color = LumenColors.TextPrimary)
        Text(now.format(DateFormat), style = MaterialTheme.typography.bodySmall, color = LumenColors.TextSecondary)
    }
}

private val TimeFormat = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
private val DateFormat = DateTimeFormatter.ofPattern("EEEE d MMMM")

/** A row of pill-shaped choices (seasons). [onFocus] lets a choice follow focus, like tvOS segmented controls. */
@Composable
fun Pills(
    labels: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    onFocus: ((Int) -> Unit)? = null,
) {
    // Lazy so a series with twenty seasons scrolls instead of overflowing.
    LazyRow(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        itemsIndexed(labels) { index, label ->
            Box(if (onFocus != null) Modifier.onFocusChanged { if (it.hasFocus) onFocus(index) } else Modifier) {
                BarItem(
                    selected = index == selected,
                    onClick = { onSelect(index) },
                    padding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                ) {
                    Text(label, style = MaterialTheme.typography.titleMedium)
                }
            }
        }
    }
}
