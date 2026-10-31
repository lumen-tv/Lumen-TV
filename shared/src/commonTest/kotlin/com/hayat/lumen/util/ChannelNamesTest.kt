package com.hayat.lumen.util

import kotlin.test.assertEquals
import kotlin.test.Test

class ChannelNamesTest {

    private fun check(raw: String, title: String, vararg tags: String) {
        val d = ChannelNames.display(raw)
        assertEquals(title, d.title, raw)
        assertEquals(tags.toList(), d.tags, raw)
    }

    @Test fun stripsCountryPrefixAndQuality() = check("UK: BBC ONE LONDON 4K ●", "BBC One London", "4K")

    @Test fun keepsAcronymsAndNumbers() = check("UK| ITV1 FHD", "ITV1", "HD")

    @Test fun pipePrefix() = check("|UK| SKY SPORTS MAIN EVENT HD", "Sky Sports Main Event", "HD")

    @Test fun bracketPrefix() = check("[US] ESPN 2 UHD", "ESPN 2", "4K")

    @Test fun superscriptTags() = check("UK: Channel 4 ᴴᴰ", "Channel 4", "HD")

    @Test fun keepsMixedCaseAsIs() = check("Sky Cinema Premiere", "Sky Cinema Premiere")

    @Test fun dropsNoiseWords() = check("UK: DAVE HEVC", "Dave")

    @Test fun bestQualityOnly() = check("UK: BBC TWO 4K HD", "BBC Two", "4K")

    @Test fun neverEmpty() = check("4K", "4K", "4K")
}
