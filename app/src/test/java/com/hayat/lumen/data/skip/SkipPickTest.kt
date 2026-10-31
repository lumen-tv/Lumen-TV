package com.hayat.lumen.data.skip

import com.hayat.lumen.data.skip.SkipSegment.Kind.CREDITS
import com.hayat.lumen.data.skip.SkipSegment.Kind.INTRO
import com.hayat.lumen.data.skip.SkipSegment.Kind.RECAP
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SkipPickTest {
    private val minute = 60_000L
    private val duration = 2_901_000L
    // A cold open: the intro starts at 5:14.
    private val coldOpen = listOf(
        SkipSegment(RECAP, 0, 45_000),
        SkipSegment(INTRO, 314_500, 331_000),
        SkipSegment(CREDITS, 2_843_000, null),
    )

    @Test fun recapThenNothingDuringTheColdOpen() {
        assertEquals(SkipOffer(RECAP, 0, 45_000), SkipPick.at(coldOpen, 10_000, duration, hasNext = true))
        assertNull(SkipPick.at(coldOpen, 2 * minute, duration, hasNext = true))
    }

    @Test fun introShowsOnlyWhileItPlays() {
        assertNull(SkipPick.at(coldOpen, 314_000, duration, hasNext = true))
        assertEquals(331_000L, SkipPick.at(coldOpen, 314_500, duration, hasNext = true)?.targetMs)
        assertEquals("Skip intro", SkipPick.at(coldOpen, 320_000, duration, hasNext = true)?.label)
        // Not worth it in the last two seconds.
        assertNull(SkipPick.at(coldOpen, 329_500, duration, hasNext = true))
    }

    @Test fun creditsOfferTheNextEpisodeOnlyWhenThereIsOne() {
        assertEquals("Next episode", SkipPick.at(coldOpen, 2_850_000, duration, hasNext = true)?.label)
        assertNull(SkipPick.at(coldOpen, 2_850_000, duration, hasNext = false))
    }

    @Test fun creditsAreTimedFromTheEndOfThisFile() {
        // The database's copy has 58 s of credits ending at 48:21; the provider's file is 3 min longer.
        val credits = listOf(SkipSegment(CREDITS, 2_843_000, 2_901_000))
        val file = 2_901_000L + 3 * minute
        assertNull(SkipPick.at(credits, 2_843_000, file, hasNext = true))
        assertNull(SkipPick.at(credits, file - 59_000, file, hasNext = true))
        assertEquals("Next episode", SkipPick.at(credits, file - 58_000, file, hasNext = true)?.label)
    }

    @Test fun creditsNeverShowBeforeTheLastTwoMinutes() {
        // Only a start time, three minutes before the end of this file.
        val credits = listOf(SkipSegment(CREDITS, 2_721_000, null))
        assertNull(SkipPick.at(credits, 2_721_000, duration, hasNext = true))
        assertNull(SkipPick.at(credits, duration - 121_000, duration, hasNext = true))
        assertEquals("Next episode", SkipPick.at(credits, duration - 120_000, duration, hasNext = true)?.label)
    }

    @Test fun creditsWithAnEndBeatAnEarlierSourceWithout() {
        val a = listOf(SkipSegment(CREDITS, 2_700_000, null))
        val b = listOf(SkipSegment(CREDITS, 2_843_000, 2_901_000))
        assertEquals(b, SkipPick.merge(listOf(a, b)))
    }

    @Test fun earlyCreditsAreBadData() {
        val bad = listOf(SkipSegment(CREDITS, 3 * minute, 4 * minute))
        assertNull(SkipPick.at(bad, 3 * minute + 1, duration, hasNext = true))
    }

    @Test fun mergeTakesTheFirstSourcePerKind() {
        val a = listOf(SkipSegment(INTRO, 100_000, 190_000))
        val b = listOf(SkipSegment(INTRO, 1, 90_000), SkipSegment(CREDITS, 2_800_000, null))
        assertEquals(listOf(a[0], b[1]), SkipPick.merge(listOf(a, emptyList(), b)))
    }

    @Test fun introsWithoutAnEndAreIgnored() {
        assertNull(SkipPick.at(listOf(SkipSegment(INTRO, 0, null)), 1_000, duration, hasNext = true))
    }
}
