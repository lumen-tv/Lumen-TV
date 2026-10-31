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
}
