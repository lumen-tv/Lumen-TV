package com.hayat.lumen.ui.vod

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import com.hayat.lumen.data.ratings.OmdbClient
import com.hayat.lumen.data.ratings.Ratings
import kotlin.math.cos
import kotlin.math.sin
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.data.db.Poster
import com.hayat.lumen.data.db.VodKind
import com.hayat.lumen.data.vod.VodRepository
import com.hayat.lumen.ui.components.QualityTag
import com.hayat.lumen.ui.theme.LumenColors
import com.hayat.lumen.util.VodNames
import kotlinx.coroutines.CancellationException

/** What the big area above the rows (and the details page) shows about a film or series. */
data class HeroInfo(
    val key: String,
    val title: String,
    val year: Int?,
    val tags: List<String>,
    val rating: Double?,
    val genre: String? = null,
    val runtimeMin: Int? = null,
    val plot: String? = null,
    val cast: String? = null,
    val director: String? = null,
    val backdropUrl: String? = null,
    val posterUrl: String? = null,
    /** IMDb, Rotten Tomatoes and age rating from OMDb, when the user added a key. */
    val ratings: Ratings? = null,
) {
    /** "2026 · Mystery, Thriller · 1 hr 54 min · ★ 6.4". */
    val meta: String
        get() = listOfNotNull(
            year?.toString(),
            genre?.split(',', '/')?.map { it.trim() }?.filter { it.isNotEmpty() }?.take(2)?.joinToString(", "),
            runtimeMin?.let(::formatRuntime),
            // The provider's own score, unless OMDb's are shown.
            rating?.takeIf { ratings == null }?.let { "★ %.1f".format(it) },
        ).joinToString("  ·  ")
}

fun formatRuntime(minutes: Int): String = when {
    minutes < 60 -> "$minutes min"
    minutes % 60 == 0 -> "${minutes / 60} hr"
    else -> "${minutes / 60} hr ${minutes % 60} min"
}

/** Quick info from the stored row, for showing something at once. */
fun Poster.quickHero(): HeroInfo {
    val name = VodNames.display(name)
    return HeroInfo(key, name.title, name.year, name.tags, rating, posterUrl = posterUrl)
}

/**
 * Full info: series rows already hold plot and backdrop; films need a `get_vod_info` call
 * (cached). If that fails, the quick info is still shown.
 */
suspend fun VodRepository.hero(poster: Poster): HeroInfo {
    val quick = poster.quickHero()
    return when (poster.kind) {
        VodKind.SERIES -> {
            val s = series(poster.sourceId, poster.itemId) ?: return quick
            quick.copy(
                year = quick.year ?: s.releaseDate?.take(4)?.toIntOrNull(),
                genre = s.genre,
                plot = s.plot,
                backdropUrl = s.backdropUrl,
            )
        }
        VodKind.MOVIE -> {
            val info = try {
                movieInfo(poster.sourceId, poster.itemId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            } ?: return quick
            quick.copy(
                year = quick.year ?: info.releaseDate?.take(4)?.toIntOrNull(),
                genre = info.genre,
                runtimeMin = info.durationSecs?.let { (it / 60).toInt() }?.takeIf { it > 0 },
                plot = info.plot,
                cast = info.cast,
                director = info.director,
                backdropUrl = info.backdropUrl,
            )
        }
    }
}

/** Adds OMDb's scores (needs the user's key; looked up by title and year). */
suspend fun OmdbClient.addRatings(hero: HeroInfo, key: String?, series: Boolean): HeroInfo =
    ratings(key, hero.title, hero.year, series)?.let { hero.copy(ratings = it) } ?: hero

/**
 * IMDb, Rotten Tomatoes and the age rating, large as in Chillio: a big mark, the score,
 * and what it is underneath. The marks are drawn, not the services' logos.
 */
@Composable
fun RatingsPanel(ratings: Ratings, modifier: Modifier = Modifier, ageCaption: Boolean = true) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(if (ageCaption) 48.dp else 36.dp)) {
        ratings.rottenTomatoes?.let {
            val fresh = (it.removeSuffix("%").toIntOrNull() ?: 0) >= 60
            Rating(score = it, caption = "Tomatometer") { Tomato(fresh, Modifier.size(MarkSize)) }
        }
        ratings.imdb?.let {
            Rating(score = it, caption = ratings.imdbVotes?.let(::formatVotes) ?: "IMDb") {
                Box(
                    Modifier.size(MarkSize).background(ImdbYellow, RoundedCornerShape(8.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "IMDb",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.ExtraBold),
                        color = Color.Black,
                    )
                }
            }
        }
        ratings.age?.let {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(
                    Modifier
                        .height(MarkSize)
                        .widthIn(min = MarkSize)
                        .border(2.dp, LumenColors.TextSecondary, RoundedCornerShape(8.dp))
                        .padding(horizontal = 10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(it, style = MaterialTheme.typography.headlineSmall, color = LumenColors.TextPrimary, maxLines = 1)
                }
                if (ageCaption) Text("Age rating", style = MaterialTheme.typography.bodyLarge, color = LumenColors.TextSecondary)
            }
        }
    }
}

@Composable
private fun Rating(score: String, caption: String, mark: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        mark()
        Column {
            Text(score, style = MaterialTheme.typography.headlineMedium, color = LumenColors.TextPrimary)
            Text(caption, style = MaterialTheme.typography.bodyLarge, color = LumenColors.TextSecondary)
        }
    }
}

/** "32.7K votes", "1.2M votes". */
fun formatVotes(votes: Int): String {
    fun short(v: Double, unit: String) = "%.1f".format(v).removeSuffix(".0") + unit
    val n = when {
        votes >= 1_000_000 -> short(votes / 1_000_000.0, "M")
        votes >= 1_000 -> short(votes / 1_000.0, "K")
        else -> votes.toString()
    }
    return "$n votes"
}

private val MarkSize = 52.dp

/** A little tomato: red and round when fresh (60% and up), a green splat when rotten. */
@Composable
private fun Tomato(fresh: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val r = size.minDimension / 2
        if (fresh) {
            drawCircle(TomatoRed, radius = r * 0.85f, center = Offset(r, r * 1.1f))
            drawOval(LeafGreen, topLeft = Offset(r * 0.55f, 0f), size = Size(r * 0.9f, r * 0.45f))
        } else {
            drawCircle(SplatGreen, radius = r * 0.8f, center = Offset(r, r))
            for (i in 0 until 6) {
                val a = i * Math.PI / 3
                drawCircle(SplatGreen, radius = r * 0.25f, center = Offset(r + (r * 0.85f * cos(a)).toFloat(), r + (r * 0.85f * sin(a)).toFloat()))
            }
        }
    }
}

private val ImdbYellow = Color(0xFFF5C518)
private val TomatoRed = Color(0xFFFA320A)
private val LeafGreen = Color(0xFF2E9E3A)
private val SplatGreen = Color(0xFF6FBF3F)

/**
 * The artwork behind the hero: the backdrop on the right two thirds, fading into the background
 * to the left and bottom so text stays readable. Without a backdrop, a blurred poster gives the colour.
 */
@Composable
fun BoxScope.Backdrop(hero: HeroInfo?, widthFraction: Float = 0.72f, heightFraction: Float = 0.75f, leftFade: Float = 0.45f) {
    val container = LocalAppContainer.current
    Crossfade(
        targetState = hero?.backdropUrl ?: hero?.posterUrl?.let { "poster:$it" },
        animationSpec = tween(500),
        label = "backdrop",
        modifier = Modifier.align(Alignment.TopEnd).fillMaxWidth(widthFraction).fillMaxHeight(heightFraction),
    ) { model ->
        if (model == null) return@Crossfade
        val isPoster = model.startsWith("poster:")
        AsyncImage(
            model = model.removePrefix("poster:"),
            contentDescription = null,
            imageLoader = container.images,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxSize()
                .then(if (isPoster) Modifier.blur(48.dp).graphicsLayer { alpha = 0.45f } else Modifier)
                .drawWithContent {
                    drawContent()
                    // Fade to the background towards the left and the bottom.
                    drawRect(
                        Brush.horizontalGradient(
                            0f to LumenColors.Background.copy(alpha = 0.92f),
                            leftFade to LumenColors.Background.copy(alpha = 0.45f),
                            1f to Color.Transparent,
                        ),
                    )
                    drawRect(Brush.verticalGradient(0.5f to Color.Transparent, 1f to LumenColors.Background))
                },
        )
    }
}

/** What the series page shows in place of the show's meta line and plot while an episode is focused. */
data class EpisodeLine(val heading: String, val plot: String?)

/**
 * Title, tags, the meta line and the plot. (The detail pages show [RatingsPanel] themselves.)
 * [episode] swaps the meta line and plot for the focused episode's; [footnote] is a small caption
 * under the plot (the TVmaze credit on the series page).
 */
@Composable
fun HeroText(
    hero: HeroInfo?,
    modifier: Modifier = Modifier,
    plotLines: Int = 3,
    titleStyle: TextStyle = MaterialTheme.typography.displaySmall,
    episode: EpisodeLine? = null,
    footnote: String? = null,
) {
    Box(modifier, contentAlignment = Alignment.BottomStart) {
        Crossfade(hero, animationSpec = tween(250), label = "heroText") { shown ->
            if (shown == null) return@Crossfade
            Column(Modifier.widthIn(max = 640.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(
                        shown.title,
                        style = titleStyle,
                        color = LumenColors.TextPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    shown.tags.forEach { QualityTag(it) }
                }
                val meta = episode?.heading ?: shown.meta
                if (meta.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(meta, style = MaterialTheme.typography.bodyLarge, color = LumenColors.TextSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                val plot = if (episode != null) episode.plot else shown.plot
                // While episodes are focused the plot keeps its full height (minLines), so moving
                // between a short and a long description doesn't make the title jump.
                if (plot != null || episode != null) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        plot ?: "",
                        style = MaterialTheme.typography.bodyLarge,
                        color = LumenColors.TextPrimary.copy(alpha = 0.85f),
                        maxLines = plotLines,
                        minLines = if (episode != null) plotLines else 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                footnote?.let {
                    Spacer(Modifier.height(6.dp))
                    Text(it, style = MaterialTheme.typography.bodySmall, color = LumenColors.TextTertiary, maxLines = 1)
                }
            }
        }
    }
}
