package com.hayat.lumen.data.skip

import com.hayat.lumen.data.skip.SkipSegment.Kind.CREDITS
import com.hayat.lumen.data.skip.SkipSegment.Kind.INTRO
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Answers copied from the three databases (Breaking Bad S1 E2), trimmed. */
class SkipTimesParseTest {
    @Test fun theIntroDb() {
        val body = """{"tmdb_id":1396,"type":"tv","season":1,"episode":2,"intro":[{"start_ms":314568,"end_ms":330969}],"credits":[{"start_ms":2843000,"end_ms":null}]}"""
        assertEquals(
            listOf(SkipSegment(INTRO, 314_568, 330_969), SkipSegment(CREDITS, 2_843_000, null)),
            SkipTimesClient.parseTheIntroDb(body),
        )
    }

    @Test fun introDb() {
        val body = """{"imdb_id":"tt0903747","intro":{"start_sec":314.5,"end_sec":331,"start_ms":314500,"end_ms":331000},"recap":null,"outro":{"start_ms":2843000,"end_ms":2901000},"no_recap":true}"""
        assertEquals(
            listOf(SkipSegment(INTRO, 314_500, 331_000), SkipSegment(CREDITS, 2_843_000, 2_901_000)),
            SkipTimesClient.parseIntroDb(body),
        )
    }

    @Test fun skipDbLeavesOutUncertainMatches() {
        val body = """{"segments":{"intro":{"start_ms":315000,"end_ms":331000,"match":"exact"},"recap":{"start_ms":0,"end_ms":40000,"match":"out-of-range"},"outro":null}}"""
        assertEquals(listOf(SkipSegment(INTRO, 315_000, 331_000)), SkipTimesClient.parseSkipDb(body))
    }

    @Test fun noIntroSentinelAndJunk() {
        assertTrue(SkipTimesClient.parseIntroDb("""{"intro":{"start_ms":0,"end_ms":0}}""").isEmpty())
        assertTrue(SkipTimesClient.parseTheIntroDb("<html>").isEmpty())
        assertTrue(SkipTimesClient.parseSkipDb("").isEmpty())
    }

    @Test fun searchPicksTheSeriesWithTheSameNameAndYear() {
        val results = JSONObject(
            """{"results":[{"tmdbId":99,"mediaType":"movie","name":"Breaking Bad","year":2008},
               {"tmdbId":5,"mediaType":"series","name":"Breaking Bad","year":1990},
               {"tmdbId":1396,"mediaType":"series","name":"Breaking Bad","year":2008}]}""",
        ).getJSONArray("results")
        assertEquals("1396", SkipTimesClient.pickSearchResult(results, "Breaking Bad", 2008))
        assertEquals("5", SkipTimesClient.pickSearchResult(results, "Breaking Bad", null))
    }
}
