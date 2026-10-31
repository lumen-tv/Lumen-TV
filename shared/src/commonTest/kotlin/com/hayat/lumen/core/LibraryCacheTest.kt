package com.hayat.lumen.core

import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class LibraryCacheTest {
    private fun tempPath(name: String) = Path(SystemTemporaryDirectory, "lumen-${Random.nextLong()}-$name").toString()

    @Test
    fun liveVodAndGuideRoundTrip() {
        val live = LiveLibrary(
            listOf(LiveCategory("UK | NEWS", "UK News", 1)),
            listOf(LiveChannel("tvg:bbc", "UK: BBC ONE HD", "BBC One", "HD", "UK | NEWS", null, "http://x/live/u/p/1.m3u8", "bbc.uk", 1)),
            epgUrl = null, skipped = 2,
        )
        val p1 = tempPath("live.json")
        LibraryCache.saveLive(live, p1)
        val back = LibraryCache.loadLive(p1)!!
        assertEquals("BBC One", back.channels.single().title)
        assertEquals(2, back.skipped)
        assertNull(back.channels.single().logoUrl)

        val vod = VodLibrary(
            listOf(VodCategory("1", "TOP", "Top", "4K", 1)),
            listOf(Movie("9", "Lupin (2021)", "Lupin", 2021, null, "1", null, 7.5, "http://x/movie/u/p/9.mkv", 1700000000L)),
            emptyList(), emptyList(),
        )
        val p2 = tempPath("vod.json")
        LibraryCache.saveVod(vod, p2)
        assertEquals(7.5, LibraryCache.loadVod(p2)!!.movies.single().rating)

        val guide = Guide(mapOf("bbc.uk" to listOf(Programme(100, 200, "News", null))))
        val p3 = tempPath("guide.json")
        LibraryCache.saveGuide(guide, p3)
        assertEquals("News", LibraryCache.loadGuide(p3)!!.nowNext("BBC.uk", 150)!!.now!!.title)
        // Saving again replaces the file.
        LibraryCache.saveGuide(Guide(emptyMap()), p3)
        assertEquals(0, LibraryCache.loadGuide(p3)!!.channelCount)
        listOf(p1, p2, p3).forEach { SystemFileSystem.delete(Path(it)) }
    }

    @Test
    fun missingOrBrokenFilesAreNoCache() {
        assertNull(LibraryCache.loadLive(tempPath("missing.json")))
        val p = tempPath("broken.json")
        SystemFileSystem.sink(Path(p)).use { }
        assertNull(LibraryCache.loadVod(p))
        SystemFileSystem.delete(Path(p))
    }
}
