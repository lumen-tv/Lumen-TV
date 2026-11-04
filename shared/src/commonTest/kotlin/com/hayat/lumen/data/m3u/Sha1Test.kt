package com.hayat.lumen.data.m3u

import kotlin.test.Test
import kotlin.test.assertEquals

class Sha1Test {
    @Test
    fun knownValues() {
        assertEquals("da39a3ee5e6b4b0d3255bfef95601890afd80709", Sha1.hex(ByteArray(0)))
        assertEquals("a9993e364706816aba3e25717850c26c9cd0d89d", Sha1.hex("abc".encodeToByteArray()))
        assertEquals(
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
            Sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".encodeToByteArray()),
        )
    }
}
