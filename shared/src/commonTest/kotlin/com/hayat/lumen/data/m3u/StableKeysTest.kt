package com.hayat.lumen.data.m3u

import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.Test

class StableKeysTest {

    private fun entry(name: String, url: String, tvgId: String? = null) =
        M3uEntry(name, url, EntryKind.LIVE, tvgId, null, null, null, null)

    @Test
    fun `tvg-id wins and is case-insensitive`() {
        assertEquals("tvg:bbc1.uk", StableKeys().keyFor(entry("BBC One", "http://h/1.ts", "BBC1.uk")))
    }

    @Test
    fun `duplicates get distinct keys`() {
        val keys = StableKeys()
        val a = keys.keyFor(entry("BBC One", "http://h/1.ts", "bbc1.uk"))
        val b = keys.keyFor(entry("BBC One HD", "http://h/2.ts", "bbc1.uk"))
        val c = keys.keyFor(entry("BBC One HD", "http://h/3.ts", "bbc1.uk"))
        assertEquals("tvg:bbc1.uk", a)
        assertEquals("tvg:bbc1.uk|bbc one hd", b)
        assertEquals("tvg:bbc1.uk|bbc one hd#2", c)
    }

    @Test
    fun `hash key survives a password change and refresh`() {
        val before = StableKeys().keyFor(entry("Channel", "http://h:80/live/user/oldpass/42.ts"))
        val after = StableKeys().keyFor(entry("Channel", "http://h:80/live/user/newpass/42.ts"))
        assertEquals(before, after)
        val other = StableKeys().keyFor(entry("Channel", "http://h:80/live/user/oldpass/43.ts"))
        assertNotEquals(before, other)
    }
}
