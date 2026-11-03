package com.hayat.lumen.data.vod

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EpisodeNotesTest {
    @Test fun stripsHtmlFromSummaries() {
        assertEquals("Logan considers his legacy & \"retires\".", EpisodeNotesClient.plainText("<p>Logan <b>considers</b> his legacy &amp; &quot;retires&quot;.</p>"))
        assertNull(EpisodeNotesClient.plainText("<p> </p>"))
    }

    @Test fun mapsEpisodesBySeasonAndNumber() {
        val body = """[
            {"season":1,"number":1,"summary":"<p>Pilot.</p>","image":{"medium":"https://img/1.jpg"}},
            {"season":1,"number":2,"summary":null,"image":null},
            {"season":1,"number":null,"summary":"<p>A special.</p>","image":null},
            {"season":2,"number":1,"summary":"","image":{"medium":"https://img/2.jpg"}}
        ]"""
        val notes = EpisodeNotesClient.parseEpisodes(body)!!
        assertEquals(EpisodeNote("Pilot.", "https://img/1.jpg"), notes["1|1"])
        assertNull(notes["1|2"]) // nothing to add
        assertEquals(EpisodeNote(null, "https://img/2.jpg"), notes["2|1"])
        assertEquals(2, notes.size) // the special has no number
    }

    @Test fun picksShowByNameAndYear() {
        val body = """[
            {"show":{"id":1,"name":"The Office","premiered":"2005-03-24"}},
            {"show":{"id":2,"name":"The Office","premiered":"2001-07-09"}},
            {"show":{"id":3,"name":"The Office Mixtape","premiered":"2020-01-01"}}
        ]"""
        assertEquals(2, EpisodeNotesClient.pickShow(body, "The Office", 2001))
        assertEquals(1, EpisodeNotesClient.pickShow(body, "the office", null))
        assertNull(EpisodeNotesClient.pickShow(body, "The Office", 1999)) // two with the name, neither from 1999
        assertEquals(3, EpisodeNotesClient.pickShow(body, "The Office: Mixtape", 1999)) // only one with the name
    }
}
