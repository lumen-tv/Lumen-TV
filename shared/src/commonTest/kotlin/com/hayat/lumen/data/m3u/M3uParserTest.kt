package com.hayat.lumen.data.m3u

import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.Test

class M3uParserTest {

    private fun parse(text: String): Pair<List<M3uEntry>, M3uParser> {
        val parser = M3uParser()
        val entries = parser.entries(text.lineSequence()).toList()
        return entries to parser
    }

    @Test
    fun `parses Xtream m3u_plus style entries`() {
        val (entries, parser) = parse(
            """
            #EXTM3U x-tvg-url="http://epg.example.com/guide.xml.gz"
            #EXTINF:-1 tvg-id="bbc1.uk" tvg-name="UK: BBC One" tvg-logo="http://img.example.com/bbc1.png" group-title="UK | Entertainment",UK: BBC One
            http://host.example.com:80/live/user/pass/1001.m3u8
            #EXTINF:-1 tvg-id="" tvg-name="Movie" tvg-logo="" group-title="Films",Some Film (2024)
            http://host.example.com:80/movie/user/pass/2002.mkv
            #EXTINF:-1 tvg-id="" tvg-name="Show S01 E01" group-title="Series",Show S01 E01
            http://host.example.com:80/series/user/pass/3003.mp4
            """.trimIndent(),
        )
        assertEquals(3, entries.size)
        val bbc = entries[0]
        assertEquals("UK: BBC One", bbc.name)
        assertEquals("bbc1.uk", bbc.tvgId)
        assertEquals("UK | Entertainment", bbc.groupTitle)
        assertEquals("http://img.example.com/bbc1.png", bbc.tvgLogo)
        assertEquals(EntryKind.LIVE, bbc.kind)
        assertNull(entries[1].tvgId) // blank attributes become null
        assertEquals(EntryKind.MOVIE, entries[1].kind)
        assertEquals(EntryKind.SERIES, entries[2].kind)
        assertEquals("http://epg.example.com/guide.xml.gz", parser.header.epgUrl)
        assertEquals(0, parser.skipped)
    }

    @Test
    fun `comma inside a quoted attribute does not end the attributes`() {
        val (entries, _) = parse(
            """
            #EXTINF:-1 group-title="News, UK" tvg-chno="101",Sky News
            http://h/s.ts
            """.trimIndent(),
        )
        assertEquals("News, UK", entries.single().groupTitle)
        assertEquals("Sky News", entries.single().name)
        assertEquals(101, entries.single().tvgChno)
    }

    @Test
    fun `plain m3u without attributes still works`() {
        val (entries, _) = parse(
            """
            #EXTM3U
            #EXTINF:-1,Channel One
            http://h/1.ts
            #EXTINF:0,Channel Two
            #EXTGRP:Sports
            http://h/2.ts
            """.trimIndent(),
        )
        assertEquals(listOf("Channel One", "Channel Two"), entries.map { it.name })
        assertNull(entries[0].groupTitle)
        assertEquals("Sports", entries[1].groupTitle)
    }

    @Test
    fun `malformed lines are skipped and never thrown`() {
        val (entries, parser) = parse(
            "\uFEFF#EXTM3U\n" +
                "#EXTINF:-1 tvg-id=\"a\"\n" + // no comma, no title
                "http://h/a.ts\n" + // URL without valid EXTINF: still kept, named from URL
                "#EXTINF:-1,Orphan\n" + // followed by another EXTINF: dropped
                "#EXTINF:-1,Good\n" +
                "not a url\n" + // garbage instead of URL: dropped
                "#EXTINF:-1,Also good\n" +
                "#EXTVLCOPT:http-user-agent=VLC\n" +
                "https://h/b.m3u8\n" +
                "#EXTINF:-1,Dangling at end\n",
        )
        assertEquals(listOf("a.ts", "Also good"), entries.map { it.name })
        assertEquals(4, parser.skipped)
    }

    @Test
    fun `attribute parsing handles quote styles and case`() {
        val attrs = M3uParser.parseAttributes("""TVG-ID="x" tvg-name='Name with spaces' tvg-chno=7""")
        assertEquals("x", attrs["tvg-id"])
        assertEquals("Name with spaces", attrs["tvg-name"])
        assertEquals("7", attrs["tvg-chno"])
    }
}
