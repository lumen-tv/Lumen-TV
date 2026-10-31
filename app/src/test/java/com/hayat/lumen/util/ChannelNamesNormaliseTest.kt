package com.hayat.lumen.util

import org.junit.Assert.assertEquals
import org.junit.Test

/** Superscript tags (NFKC) and resolution names. */
class ChannelNamesNormaliseTest {
    private fun check(raw: String, title: String, vararg tags: String) =
        assertEquals(DisplayName(title, tags.toList()), ChannelNames.display(raw))

    @Test fun superscriptResolution() = check("SKY SPORTS MAIN EVENT ³⁸⁴⁰ᴾ", "Sky Sports Main Event", "4K")
    @Test fun superscriptOnShortName() = check("SKY SPORTS F1 ³⁸⁴⁰ᴾ", "Sky Sports F1", "4K")
    @Test fun plainResolution() = check("UK: SKY SPORTS F1 3840P", "Sky Sports F1", "4K")
    @Test fun trademarkSignGoes() = check("Discovery™ HD", "Discovery", "HD")
}
