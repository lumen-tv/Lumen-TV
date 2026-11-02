package com.hayat.lumen.ui.components

import android.graphics.Bitmap
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.ColorUtils
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import com.hayat.lumen.LocalAppContainer
import com.hayat.lumen.ui.theme.LumenColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Lumen's "working on it" sign, in place of a spinner (Hayat 2026-11-02, same as the iPhone app):
 * a thin line with a soft light passing through it. Fills the width it's given, up to [maxWidth].
 */
@Composable
fun LoadingLine(modifier: Modifier = Modifier, maxWidth: Dp = Dp.Infinity) {
    val sweep by rememberInfiniteTransition(label = "loadingLine").animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1600, easing = FastOutSlowInEasing), RepeatMode.Restart),
        label = "sweep",
    )
    Box(
        modifier
            .widthIn(max = maxWidth)
            .fillMaxWidth()
            .height(3.dp)
            .clip(RoundedCornerShape(50))
            .background(Color.White.copy(alpha = 0.18f))
            // Read in the draw phase only: the light moves without recomposing anything
            // (unlike SwiftUI, where an animated value always goes through the view body).
            .drawBehind {
                val band = size.width * 0.4f
                val x = -band + sweep * (size.width + band)
                drawRect(
                    Brush.horizontalGradient(listOf(Color.Transparent, Color.White, Color.Transparent), startX = x, endX = x + band),
                    topLeft = Offset(x, 0f),
                    size = size.copy(width = band),
                )
            },
    )
}

/**
 * The screen while a film, episode or channel starts (Hayat 2026-11-02, as on the iPhone): the
 * colours of its poster blurred into a soft wash that drifts slowly (without a poster, a wash of
 * [colour]), and in the middle, big: the name, a detail line ("S1 · E3 Title", or what's on), what's
 * happening ("Resuming from 42:10"), and the [LoadingLine]. The player fades it out when the picture appears.
 */
@Composable
fun PlaybackLoading(
    artUrl: String?,
    heading: String,
    modifier: Modifier = Modifier,
    colour: Color = DefaultWash,
    detail: String? = null,
    status: String? = null,
) {
    PlaybackLoadingContent(rememberColourWash(artUrl), heading, modifier, colour, detail, status)
}

/** [PlaybackLoading] with the poster's wash already made (screenshots pass their own). */
@Composable
internal fun PlaybackLoadingContent(
    wash: ImageBitmap?,
    heading: String,
    modifier: Modifier = Modifier,
    colour: Color = DefaultWash,
    detail: String? = null,
    status: String? = null,
) {
    val drift by rememberInfiniteTransition(label = "drift").animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(14_000, easing = LinearEasing), RepeatMode.Reverse),
        label = "drift",
    )
    Box(modifier.fillMaxSize().background(Color.Black)) {
        if (wash != null) {
            // A tiny, already blurred copy of the poster stretched over the screen: only its colours
            // are left, no shapes. Smooth because it's drawn with filtering, and cheap on the 2 GB TV
            // (a real blur of the full-size poster isn't). Moved in the draw layer, so no recomposing.
            Image(
                bitmap = wash,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                filterQuality = FilterQuality.High,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val scale = 1.4f * (1f + 0.12f * drift)
                        scaleX = scale
                        scaleY = scale
                        translationX = -size.width * 0.04f * drift
                    },
            )
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.25f)))
        } else {
            Box(
                Modifier.fillMaxSize().drawBehind {
                    drawRect(colour)
                    drawRect(
                        Brush.radialGradient(
                            listOf(Color.White.copy(alpha = 0.16f), Color.Transparent),
                            center = Offset(size.width * (0.9f - 0.1f * drift), 0f),
                            radius = size.width * 0.55f,
                        ),
                    )
                    drawRect(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.35f))))
                },
            )
        }
        // An even dim, so the text reads on any colours.
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f)))

        // Big, in the middle of the screen (Hayat 2026-11-02: not small in the corner).
        Column(
            Modifier.align(Alignment.Center).widthIn(max = 900.dp).padding(horizontal = 48.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (heading.isNotEmpty()) {
                Text(
                    heading,
                    style = MaterialTheme.typography.displayMedium.copy(fontWeight = FontWeight.Bold, fontSize = 52.sp, lineHeight = 60.sp),
                    color = LumenColors.TextPrimary,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            detail?.takeIf { it.isNotBlank() }?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.headlineSmall,
                    color = LumenColors.TextPrimary,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            status?.let {
                Text(it, style = MaterialTheme.typography.titleLarge, color = LumenColors.TextSecondary, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.height(14.dp))
            LoadingLine(maxWidth = 420.dp)
        }
    }
}

/** The thin line along the bottom of the picture, for a hiccup once it's playing. */
@Composable
fun BufferingLine(modifier: Modifier = Modifier) {
    LoadingLine(modifier.padding(horizontal = 48.dp, vertical = 18.dp))
}

private val DefaultWash = Color(0xFF0F1730)

/** Loads [url] small and turns it into the loading screen's colour wash (null without one, or until it's ready). */
@Composable
private fun rememberColourWash(url: String?): ImageBitmap? {
    if (url.isNullOrBlank()) return null
    val context = LocalContext.current
    val images = LocalAppContainer.current.images
    var wash by remember(url) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(url) {
        val request = ImageRequest.Builder(context)
            .data(url)
            .size(96) // only the colours matter
            .allowHardware(false) // we read the pixels
            .build()
        val result = images.execute(request) as? SuccessResult ?: return@LaunchedEffect
        wash = withContext(Dispatchers.Default) { ColourWash.from(result.image.toBitmap()).asImageBitmap() }
    }
    return wash
}

/** Shrinks a picture to a few pixels, blurs it and lifts the colour a little, like the iPhone's wash. */
internal object ColourWash {
    fun from(source: Bitmap): Bitmap {
        val w = 24
        val h = (w * source.height / source.width.coerceAtLeast(1)).coerceIn(12, 48)
        val small = Bitmap.createScaledBitmap(source, w, h, true)
        val px = IntArray(w * h)
        small.getPixels(px, 0, w, 0, 0, w, h)
        repeat(3) { boxBlur(px, w, h, radius = 2) }
        val hsl = FloatArray(3)
        for (i in px.indices) {
            ColorUtils.colorToHSL(px[i] or (0xFF shl 24), hsl)
            hsl[1] = (hsl[1] * 1.25f).coerceAtMost(1f)
            px[i] = ColorUtils.HSLToColor(hsl)
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    /** One horizontal and one vertical pass of a box blur, edges clamped. */
    private fun boxBlur(px: IntArray, w: Int, h: Int, radius: Int) {
        val out = IntArray(px.size)
        fun pass(get: (Int, Int) -> Int, set: (Int, Int, Int) -> Unit, length: Int, lines: Int) {
            for (line in 0 until lines) {
                for (i in 0 until length) {
                    var r = 0; var g = 0; var b = 0
                    for (k in -radius..radius) {
                        val c = get(line, (i + k).coerceIn(0, length - 1))
                        r += (c shr 16) and 0xFF; g += (c shr 8) and 0xFF; b += c and 0xFF
                    }
                    val n = radius * 2 + 1
                    set(line, i, (0xFF shl 24) or ((r / n) shl 16) or ((g / n) shl 8) or (b / n))
                }
            }
        }
        pass({ y, x -> px[y * w + x] }, { y, x, c -> out[y * w + x] = c }, w, h)
        pass({ x, y -> out[y * w + x] }, { x, y, c -> px[y * w + x] = c }, h, w)
    }
}
