package com.hayat.lumen.core

import com.hayat.lumen.util.ChannelNames
import com.hayat.lumen.util.UrlRedaction
import kotlin.test.Test
import kotlin.test.assertEquals

/** Runs the moved regex code on every platform (the Android tests in app/ cover the details). */
class NamesTest {
    @Test
    fun channelNames() {
        assertEquals("BBC One London", ChannelNames.title("UK: BBC ONE LONDON 4K ●"))
        assertEquals(listOf("4K"), ChannelNames.display("UK: BBC ONE LONDON 4K ●").tags)
        assertEquals("Sky Sports Main Event", ChannelNames.title("|UK| SKY SPORTS MAIN EVENT FHD"))
        assertEquals("Rock-N-Roll", ChannelNames.title("ROCK-N-ROLL"))
    }

    @Test
    fun redaction() {
        assertEquals("cf.example.com", UrlRedaction.hostOnly("http://user:pw@cf.example.com:8080/x"))
        assertEquals("http://cf.example.com:8080/live/1.ts", UrlRedaction.withoutCredentials("http://cf.example.com:8080/live/u/p/1.ts?token=x"))
        assertEquals("the server", UrlRedaction.hostOnly("not a url"))
    }
}
