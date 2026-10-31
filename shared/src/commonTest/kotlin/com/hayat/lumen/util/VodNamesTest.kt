package com.hayat.lumen.util

import kotlin.test.assertEquals
import kotlin.test.Test

class VodNamesTest {
    @Test
    fun stripsProviderPrefixYearAndCountry() {
        assertEquals(VodNames.Name("Lupin", 2021, listOf("4K")), VodNames.display("4K-NF - Lupin (2021) (FR)"))
        assertEquals(VodNames.Name("Dear David", 2023, emptyList()), VodNames.display("EN - Dear David  (2023)"))
        assertEquals(VodNames.Name("The Envoys", 2021, emptyList()), VodNames.display("P+ - The Envoys (2021) (AR)"))
        assertEquals(VodNames.Name("Dear White People", null, emptyList()), VodNames.display("NF - Dear White People (US)"))
        assertEquals(VodNames.Name("The Goat Life (Aadujeevitham)", 2024, emptyList()), VodNames.display("TOP - The Goat Life (Aadujeevitham) (2024)"))
    }

    @Test
    fun keepsTitlesThatOnlyLookLikePrefixes() {
        assertEquals("A+ Highest 2 Lowest", VodNames.display("A+ Highest 2 Lowest (2025)").title)
        assertEquals("Leinster - Munster", VodNames.display("Leinster - Munster").title)
        assertEquals("Suzhal - The Vortex", VodNames.display("4K-AMZ - Suzhal - The Vortex (2022) (IN)").title)
        assertEquals("1917", VodNames.display("1917").title)
    }

    @Test
    fun cleansEpisodeTitles() {
        val mf = "Modern Family"
        assertEquals("Come Fly with Me", VodNames.episode("D+ - Modern Family S01E03 - Come Fly with Me", mf))
        assertEquals("Come Fly with Me", VodNames.episode("D+ - Modern Family - S01 E03 - Come Fly with Me", mf))
        assertEquals("Chapter 1", VodNames.episode("Lupin - S01E01 - Chapter 1"))
        assertEquals("Pilot", VodNames.episode("Lost 1x01 Pilot"))
        // No code: the provider tag and the show's name still go.
        assertEquals("Come Fly with Me", VodNames.episode("D+ - Come Fly with Me", mf))
        assertEquals("Come Fly with Me", VodNames.episode("D+ - Modern Family - Come Fly with Me", mf))
        assertEquals("The Bicycle Thief", VodNames.episode("Episode 3: The Bicycle Thief"))
        assertEquals("Pilot", VodNames.episode("NF - Lupin S01E01 Pilot [1080p]"))
        assertEquals("Pilot", VodNames.episode("Pilot (2009)"))
    }

    @Test
    fun episodeTitleIsNullWhenOnlyCodesAreLeft() {
        assertEquals(null, VodNames.episode("Lupin - S04E08"))
        assertEquals(null, VodNames.episode("D+ - Modern Family S01E03", "Modern Family"))
        assertEquals(null, VodNames.episode("D+ - Modern Family", "Modern Family"))
        assertEquals(null, VodNames.episode("Episode 8"))
        assertEquals(null, VodNames.episode("  "))
        assertEquals(null, VodNames.episode(null))
    }

    @Test
    fun keepsEpisodeTitlesThatOnlyLookLikeNoise() {
        assertEquals("Lost Souls", VodNames.episode("Lost Souls", "Lost"))
        assertEquals("To Be Continued...", VodNames.episode("To Be Continued..."))
        assertEquals("Leinster - Munster", VodNames.episode("Leinster - Munster"))
        assertEquals("Eleven", VodNames.episode("Eleven"))
    }
}
