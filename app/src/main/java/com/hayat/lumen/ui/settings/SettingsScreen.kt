package com.hayat.lumen.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.ratings.KeyCheck
import com.hayat.lumen.ui.categories.LiveCategoriesSection
import com.hayat.lumen.ui.components.LumenButton
import com.hayat.lumen.ui.components.LumenListItem
import com.hayat.lumen.ui.components.LumenTextField
import com.hayat.lumen.ui.guide.GuideSettingsSection
import com.hayat.lumen.ui.components.ambient
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.ui.theme.SafeArea
import kotlinx.coroutines.launch

enum class SettingsSection(val title: String) {
    PLAYLISTS("Playlists"),
    GUIDE("TV guide"),
    LIVE_CATEGORIES("Live categories"),
    MOVIE_CATEGORIES("Movie categories"),
    SERIES_CATEGORIES("Series categories"),
    RATINGS("Ratings"),
    UPDATES("Updates"),
    ABOUT("About"),
}

/**
 * Everything you set once: a menu on the left, the highlighted section on the right.
 * Like tvOS Settings, moving down the menu swaps the right side; Right goes into it.
 */
@Composable
fun SettingsScreen(
    initial: SettingsSection,
    onAddPlaylist: () -> Unit,
    onNoPlaylists: () -> Unit,
    onOpenUpdate: () -> Unit,
) {
    val container = LocalAppContainer.current
    // rememberSaveable: still on the same section after coming back from Add playlist.
    var section by rememberSaveable { mutableStateOf(initial) }
    val update by container.updates.available.collectAsStateWithLifecycle()
    val menuFocus = remember { FocusRequester() }

    Row(
        Modifier
            .fillMaxSize()
            .ambient()
            .padding(horizontal = SafeArea.Horizontal, vertical = SafeArea.Vertical),
    ) {
        Column(Modifier.width(280.dp).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Settings", style = MaterialTheme.typography.headlineLarge, color = LumenColors.TextPrimary)
            Spacer(Modifier.height(16.dp))
            SettingsSection.entries.forEach { s ->
                LumenListItem(
                    onClick = { section = s },
                    selected = s == section,
                    minHeight = 48.dp,
                    modifier = Modifier
                        .then(if (s == section) Modifier.focusRequester(menuFocus) else Modifier)
                        .onFocusChanged { if (it.isFocused) section = s },
                ) {
                    Text(s.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    if (s == SettingsSection.UPDATES && update != null) UpdateDot()
                }
            }
        }
        Spacer(Modifier.width(40.dp))
        Column(Modifier.weight(1f).fillMaxHeight()) {
            Text(section.title, style = MaterialTheme.typography.headlineSmall, color = LumenColors.TextPrimary)
            Spacer(Modifier.height(12.dp))
            val pane = Modifier.fillMaxSize()
            when (section) {
                SettingsSection.PLAYLISTS -> PlaylistsSection(onAddPlaylist, onNoPlaylists, pane)
                SettingsSection.GUIDE -> GuideSettingsSection(pane)
                SettingsSection.LIVE_CATEGORIES -> LiveCategoriesSection(pane)
                SettingsSection.MOVIE_CATEGORIES -> VodCategoriesSection(VodKind.MOVIE, pane)
                SettingsSection.SERIES_CATEGORIES -> VodCategoriesSection(VodKind.SERIES, pane)
                SettingsSection.RATINGS -> RatingsSection(pane)
                SettingsSection.UPDATES -> UpdatesSection(onOpenUpdate, pane)
                SettingsSection.ABOUT -> AboutSection(pane)
            }
        }
    }

    LaunchedEffect(Unit) { runCatching { menuFocus.requestFocus() } }
}

/** The small blue dot that says "an update is waiting" (also on the Settings tab). */
@Composable
fun UpdateDot(modifier: Modifier = Modifier) {
    Box(modifier.size(10.dp).background(LumenColors.Accent, CircleShape))
}

@Composable
private fun RatingsSection(modifier: Modifier = Modifier) {
    val container = LocalAppContainer.current
    val saved by container.prefs.omdbKey.collectAsStateWithLifecycle()
    var key by remember { mutableStateOf(saved.orEmpty()) }
    var result by remember { mutableStateOf<String?>(null) }
    var checking by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(
            "Film and series pages can show IMDb and Rotten Tomatoes scores and the age rating, from OMDb. " +
                "Get a free key at omdbapi.com (choose FREE, then open the link in the email), and type it here. " +
                "It stays on this TV.",
            style = MaterialTheme.typography.bodyLarge,
            color = LumenColors.TextSecondary,
        )
        LumenTextField(
            value = key,
            onValueChange = { key = it },
            label = "OMDb key",
            placeholder = "e.g. 1a2b3c4d",
            keyboardType = KeyboardType.Ascii,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            LumenButton(
                text = if (checking) "Checking…" else "Save",
                enabled = !checking && key.isNotBlank() && key.trim() != saved,
                onClick = {
                    checking = true
                    scope.launch {
                        result = when (container.omdb.check(key)) {
                            KeyCheck.WORKS -> {
                                container.prefs.setOmdbKey(key)
                                "Saved. The key works."
                            }
                            KeyCheck.REJECTED -> "OMDb doesn't accept this key. Check it, and that you opened the link in OMDb's email."
                            KeyCheck.UNREACHABLE -> {
                                container.prefs.setOmdbKey(key) // probably just offline: keep it
                                "Saved, but OMDb couldn't be reached to check it."
                            }
                        }
                        checking = false
                    }
                },
            )
            if (saved != null) {
                LumenButton(text = "Remove key", onClick = {
                    container.prefs.setOmdbKey(null)
                    key = ""
                    result = "Removed. Pages show your provider's rating only."
                })
            }
        }
        result?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = LumenColors.TextPrimary) }
    }
}

@Composable
private fun UpdatesSection(onOpenUpdate: () -> Unit, modifier: Modifier = Modifier) {
    val updates = LocalAppContainer.current.updates
    val available by updates.available.collectAsStateWithLifecycle()
    var checked by remember { mutableStateOf(false) }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("You have Lumen ${updates.currentVersion}.", style = MaterialTheme.typography.bodyLarge, color = LumenColors.TextSecondary)
        val ready = available
        if (ready != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                UpdateDot()
                Text("Lumen ${ready.version} is ready to install.", style = MaterialTheme.typography.titleMedium, color = LumenColors.TextPrimary)
            }
        }
        Row {
            // One button that turns from "Check for updates" into "Update to …" when GitHub has a newer
            // version. Two separate buttons would remove the focused one, and on the TV Android then hands
            // focus to the top of the menu (Playlists) at once, before Lumen could move it anywhere.
            LumenButton(
                text = if (ready != null) "Update to ${ready.version}" else "Check for updates",
                onClick = {
                    if (ready != null) {
                        onOpenUpdate()
                    } else {
                        updates.checkInBackground(force = true)
                        checked = true
                    }
                },
            )
        }
        if (ready == null && checked) {
            Text(
                "Checking GitHub… If a newer version is out, it shows here in a moment.",
                style = MaterialTheme.typography.bodyMedium,
                color = LumenColors.TextSecondary,
            )
        }
        Text(
            "Lumen also checks by itself when it starts and every few hours.",
            style = MaterialTheme.typography.bodyMedium,
            color = LumenColors.TextTertiary,
        )
    }
}

@Composable
private fun AboutSection(modifier: Modifier = Modifier) {
    val version = LocalAppContainer.current.updates.currentVersion
    // Plain text, so the D-pad has nothing to land on; the scroll lets a long page still move.
    Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        listOf(
            "Lumen $version, a minimal IPTV player for Google TV.",
            "Lumen has no account and collects nothing. Your playlists and logins stay on this TV. " +
                "Privacy policy: github.com/lumen-tv/Lumen-TV/blob/main/PRIVACY.md",
            "Updates come from github.com/lumen-tv/Lumen-TV. Website: lumen-tv.github.io",
            "Font: Inter (SIL Open Font License). Channel logos: tv-logo/tv-logos. Ratings: OMDb.",
        ).forEach { Text(it, style = MaterialTheme.typography.bodyLarge, color = LumenColors.TextSecondary) }
    }
}
