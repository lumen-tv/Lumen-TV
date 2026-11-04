package com.hayat.lumen.util

import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.Test

class UrlRedactionTest {

    @Test
    fun `host only drops everything sensitive`() {
        assertEquals("cf.example.com", UrlRedaction.hostOnly("http://cf.example.com:80/get.php?username=u&password=p&type=m3u"))
        assertEquals("the server", UrlRedaction.hostOnly("not a url"))
    }

    @Test
    fun `without credentials strips query and user-info and Xtream path segments`() {
        val out = UrlRedaction.withoutCredentials("http://me:secret@h.example.com:8080/live/user/pass/123.ts?token=abc")
        assertEquals("http://h.example.com:8080/live/123.ts", out)
        assertFalse("secret" in out || "pass" in out || "abc" in out)
    }
}
