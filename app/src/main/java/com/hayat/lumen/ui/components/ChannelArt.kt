package com.hayat.lumen.ui.components

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.graphics.ColorUtils
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import androidx.core.graphics.scale
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.ui.theme.LumenColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Channel artwork that fills its box edge to edge, Apple TV style: the background is the
 * logo's own colour, so a logo printed on a solid block (BBC One's red square) blends into
 * one solid tile, and a transparent logo sits on a deep wash of its main colour. Shows a
 * monogram on a muted tile while the logo loads or if there isn't one. The main UK channels
 * use built-in artwork instead ([BrandLogos]).
 *
 * [logoFraction] is how much of the box's height the logo may use.
 */
@Composable
fun ChannelArt(
    name: String,
    logoUrl: String?,
    modifier: Modifier = Modifier,
    logoFraction: Float = DEFAULT_LOGO_FRACTION,
    onTint: (Color) -> Unit = {},
) {
    val brand = remember(name) { BrandLogos.forName(name) }
    if (brand != null) {
        BrandTile(brand, name, modifier, logoFraction, onTint)
        return
    }
    val art = rememberLogoArt(logoUrl)
    val base by animateColorAsState(art?.tint?.background ?: LumenColors.Surface, label = "artBg")
    LaunchedEffect(art) { art?.let { onTint(it.tint.background) } }
    BoxWithConstraints(
        modifier.background(
            // A touch lighter at the top, like light falling on glass.
            Brush.verticalGradient(listOf(lerp(base, Color.White, 0.08f), base, lerp(base, Color.Black, 0.12f))),
        ),
        contentAlignment = Alignment.Center,
    ) {
        if (art == null) {
            Monogram(name, size = maxHeight * 0.5f)
        } else {
            // Logos on their own solid block are drawn bigger: their edges disappear into the tile.
            val fraction = if (art.tint.opaqueEdges) logoFraction + 0.12f else logoFraction
            Image(
                bitmap = art.logo,
                contentDescription = name,
                contentScale = ContentScale.Fit,
                modifier = Modifier.size(width = maxWidth * 0.7f, height = maxHeight * fraction),
            )
        }
    }
}

/** Built-in artwork for a main channel: its brand colour edge to edge, with a clean logo. */
@Composable
private fun BrandTile(brand: Brand, name: String, modifier: Modifier, logoFraction: Float, onTint: (Color) -> Unit) {
    LaunchedEffect(brand) { onTint(brand.tile) }
    val base = brand.tile
    BoxWithConstraints(
        modifier.background(
            Brush.verticalGradient(listOf(lerp(base, Color.White, 0.1f), base, lerp(base, Color.Black, 0.15f))),
        ),
        contentAlignment = Alignment.Center,
    ) {
        // Small tiles (list rows) get relatively bigger logos than the large cards.
        val fraction = (brand.logoFraction + (logoFraction - DEFAULT_LOGO_FRACTION)).coerceAtMost(0.8f)
        Image(
            painter = painterResource(brand.logo),
            contentDescription = name,
            contentScale = ContentScale.Fit,
            colorFilter = brand.logoTint?.let { ColorFilter.tint(it) },
            modifier = Modifier.size(width = maxWidth * 0.74f, height = maxHeight * fraction),
        )
    }
}

private const val DEFAULT_LOGO_FRACTION = 0.56f

/** A small rounded logo tile for list rows and the player overlay. */
@Composable
fun ChannelLogo(name: String, logoUrl: String?, size: Dp, modifier: Modifier = Modifier) {
    ChannelArt(
        name = name,
        logoUrl = logoUrl,
        logoFraction = 0.62f,
        modifier = modifier
            .size(width = size * 16 / 9, height = size)
            .clip(RoundedCornerShape(size * 0.2f)),
    )
}

/**
 * The colour of a channel's tile ([ChannelArt]'s background), for the player's loading screen.
 * Grey/white logos and channels without one get the monogram's colour from the name.
 */
@Composable
fun rememberChannelColour(name: String, logoUrl: String?): Color {
    BrandLogos.forName(name)?.let { return it.tile }
    val tint = rememberLogoArt(logoUrl)?.tint?.background
    return if (tint == null || tint == LumenColors.SurfaceFocused) remember(name) { Monograms.colorFor(name) } else tint
}

@Immutable
private class LogoArt(val logo: ImageBitmap, val tint: Tint)

private data class Tint(val background: Color, val opaqueEdges: Boolean)

/** Loads [url] through the app's image loader and works out the tile colour once per logo. */
@Composable
private fun rememberLogoArt(url: String?): LogoArt? {
    if (url.isNullOrBlank()) return null
    val context = LocalContext.current
    val images = LocalAppContainer.current.images
    var art by remember(url) { mutableStateOf<LogoArt?>(null) }
    LaunchedEffect(url) {
        val request = ImageRequest.Builder(context)
            .data(url)
            .size(480) // logos are shown small; keeps decoded bitmaps light on the 2 GB TV
            .allowHardware(false) // we read pixels, and hardware bitmaps can't be read
            .build()
        // Coil's memory cache makes this instant after the first load.
        val result = images.execute(request) as? SuccessResult ?: return@LaunchedEffect
        art = withContext(Dispatchers.Default) {
            val bitmap = result.image.toBitmap()
            val tint = TintCache[url] ?: tintFor(bitmap).also { TintCache[url] = it }
            LogoArt(bitmap.asImageBitmap(), tint)
        }
    }
    return art
}

/** Remembers each logo's computed colour (not its pixels; Coil caches those) for the session. */
private object TintCache {
    private val map = object : LinkedHashMap<String, Tint>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Tint>) = size > 500
    }

    @Synchronized operator fun get(url: String): Tint? = map[url]
    @Synchronized operator fun set(url: String, tint: Tint) {
        map[url] = tint
    }
}

/**
 * The tile colour for a logo. If the logo's border is solid and one colour, that's the
 * background and the logo can be drawn bigger. Otherwise a deep version of the logo's main colour,
 * or a neutral dark grey for white/black/grey logos.
 */
private fun tintFor(bitmap: Bitmap): Tint {
    val n = 24
    val small = bitmap.scale(n, n)
    val px = IntArray(n * n).also { small.getPixels(it, 0, n, 0, 0, n, n) }
    if (small !== bitmap) small.recycle()

    val edge = buildList {
        for (i in 0 until n) {
            add(px[i]); add(px[(n - 1) * n + i]); add(px[i * n]); add(px[i * n + n - 1])
        }
    }
    val opaqueEdge = edge.filter { android.graphics.Color.alpha(it) > 230 }
    if (opaqueEdge.size > edge.size * 0.9) {
        val avg = average(opaqueEdge)
        val spread = opaqueEdge.count { distance(it, avg) < 40 }
        if (spread > opaqueEdge.size * 0.8) return Tint(Color(avg), opaqueEdges = true)
    }

    // Transparent background: tint with the most saturated common colour in the logo.
    val visible = px.filter { android.graphics.Color.alpha(it) > 200 }
    val hsl = FloatArray(3)
    val colourful = visible.filter {
        ColorUtils.colorToHSL(it, hsl)
        hsl[1] > 0.35f && hsl[2] in 0.15f..0.85f
    }
    if (colourful.size < visible.size * 0.15f || colourful.isEmpty()) return Tint(LumenColors.SurfaceFocused, opaqueEdges = false)
    ColorUtils.colorToHSL(average(colourful), hsl)
    hsl[1] = hsl[1].coerceAtMost(0.6f)
    hsl[2] = 0.22f // deep enough for a white or coloured logo to read on it
    return Tint(Color(ColorUtils.HSLToColor(hsl)), opaqueEdges = false)
}

private fun average(colors: List<Int>): Int {
    var r = 0L; var g = 0L; var b = 0L
    for (c in colors) {
        r += android.graphics.Color.red(c); g += android.graphics.Color.green(c); b += android.graphics.Color.blue(c)
    }
    val n = colors.size.coerceAtLeast(1)
    return android.graphics.Color.rgb((r / n).toInt(), (g / n).toInt(), (b / n).toInt())
}

private fun distance(a: Int, b: Int): Int =
    maxOf(
        kotlin.math.abs(android.graphics.Color.red(a) - android.graphics.Color.red(b)),
        kotlin.math.abs(android.graphics.Color.green(a) - android.graphics.Color.green(b)),
        kotlin.math.abs(android.graphics.Color.blue(a) - android.graphics.Color.blue(b)),
    )

/** A small outlined chip for a channel's quality, e.g. "4K". */
@Composable
fun QualityTag(text: String, modifier: Modifier = Modifier, color: Color = LumenColors.TextSecondary) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = color,
        maxLines = 1,
        modifier = modifier
            .border(1.dp, color.copy(alpha = 0.6f), RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 1.dp),
    )
}
