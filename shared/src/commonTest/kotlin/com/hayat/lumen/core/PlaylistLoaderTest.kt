package com.hayat.lumen.core

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlaylistLoaderTest {

    private fun loader(handler: (url: String) -> Pair<HttpStatusCode, String>) = PlaylistLoader(
        HttpClient(MockEngine { request ->
            val (status, body) = handler(request.url.toString())
            respond(body, status)
        }),
    )

    private val account = """{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8","ts"]},"server_info":{}}"""
    private val categories = """[{"category_id":"2","category_name":"UK | NEWS ᴴᴰ","parent_id":0},{"category_id":1,"category_name":"Sport"},{"category_id":"9","category_name":"Empty"}]"""
    private val streams = """
        [
          {"num":1,"name":"UK: BBC NEWS HD","stream_type":"live","stream_id":101,"stream_icon":"http://img/bbc.png","epg_channel_id":"bbcnews.uk","category_id":"2"},
          {"num":"2","name":"Sky Sports 4K","stream_id":"102","stream_icon":"","epg_channel_id":null,"category_id":1,"tv_archive":0,"category_ids":[1]},
          {"name":"No id"},
          {"stream_id":103,"name":"  "}
        ]
    """.trimIndent()

    private fun xtreamServer(url: String): Pair<HttpStatusCode, String> = when {
        "action=get_live_categories" in url -> HttpStatusCode.OK to categories
        "action=get_live_streams" in url -> HttpStatusCode.OK to streams
        "player_api.php" in url -> HttpStatusCode.OK to account
        else -> HttpStatusCode.NotFound to ""
    }

    @Test
    fun loadsXtreamChannelsInCategoryOrder() = runTest {
        val library = loader(::xtreamServer).loadXtream("cf.example.com:8080", "user", "p/s?s")
        assertEquals(listOf("UK | NEWS ᴴᴰ", "Sport"), library.categories.map { it.name })
        assertEquals(listOf(1, 1), library.categories.map { it.channelCount })
        assertEquals(2, library.channels.size)
        val bbc = library.channels[0]
        assertEquals("BBC News", bbc.title)
        assertEquals("HD", bbc.quality)
        assertEquals("tvg:bbcnews.uk", bbc.key)
        assertEquals("http://cf.example.com:8080/live/user/p%2Fs%3Fs/101.m3u8", bbc.streamUrl)
        assertEquals("UK | NEWS ᴴᴰ", bbc.categoryName)
        val sky = library.channels[1]
        assertNull(sky.logoUrl)
        assertEquals(2, sky.number)
        assertEquals("4K", sky.quality)
        assertTrue(sky.key.startsWith("h:"))
    }

    @Test
    fun wrongLoginIsRefused() = runTest {
        val e = assertFailsWith<LoadException> {
            loader { HttpStatusCode.OK to "[]" }.loadXtream("cf.example.com", "user", "wrong")
        }
        assertEquals("cf.example.com didn't accept that username and password.", e.message)
        assertFailsWith<LoadException> {
            loader { HttpStatusCode.OK to """{"user_info":{"auth":0}}""" }.loadXtream("cf.example.com", "u", "p")
        }
    }

    @Test
    fun expiredAccount() = runTest {
        val e = assertFailsWith<LoadException> {
            loader { HttpStatusCode.OK to """{"user_info":{"auth":"1","status":"Expired"}}""" }
                .loadXtream("http://cf.example.com/", "u", "p")
        }
        assertEquals("This subscription on cf.example.com has expired.", e.message)
    }

    @Test
    fun httpErrorsAreWorded() = runTest {
        val e = assertFailsWith<LoadException> {
            loader { HttpStatusCode.fromValue(884) to "" }.loadXtream("cf.example.com", "u", "p")
        }
        assertEquals("cf.example.com answered with error 884. Check the address and your login.", e.message)
    }

    @Test
    fun getPhpLinkGoesThroughTheApi() = runTest {
        var asked = ""
        val library = loader { url -> asked += url + "\n"; xtreamServer(url) }
            .loadM3u("http://cf.example.com:80/get.php?username=user&password=pass&type=m3u_plus&output=ts")
        assertEquals(2, library.channels.size)
        assertTrue("get.php" !in asked)
        assertEquals("http://cf.example.com/live/user/pass/101.m3u8", library.channels[0].streamUrl)
    }

    @Test
    fun loadsM3uLinks() = runTest {
        val m3u = """
            #EXTM3U url-tvg="http://epg.example.com/guide.xml"
            #EXTINF:-1 tvg-id="one.uk" tvg-logo="http://img/1.png" group-title="News",UK: ONE NEWS
            http://stream.example.com/1.m3u8
            #EXTINF:-1 group-title="Films",A Film
            http://stream.example.com/movie/u/p/2.mkv
            #EXTINF:-1,No group
            http://stream.example.com/3.ts
        """.trimIndent()
        val library = loader { HttpStatusCode.OK to m3u }.loadM3u("https://lists.example.com/my.m3u")
        assertEquals(listOf("News"), library.categories.map { it.name })
        assertEquals(listOf("One News", "No group"), library.channels.map { it.title })
        assertEquals("http://epg.example.com/guide.xml", library.epgUrl)
    }

    @Test
    fun typedServers() {
        assertEquals("http://cf.example.com:8080", XtreamServer.of(" cf.example.com:8080 ", "u", "p")!!.base.toString())
        assertEquals("https://example.com/panel", XtreamServer.of("https://example.com/panel/", "u", "p")!!.base.toString())
        assertNull(XtreamServer.of("not a server", "u", "p"))
        assertNull(XtreamServer.of("cf.example.com", "", "p"))
        val link = XtreamServer.fromPlaylistUrl("http://h.example.com:25461/sub/get.php?username=a&password=b&type=m3u")!!
        assertEquals("http://h.example.com:25461/sub", link.base.toString())
        assertNull(XtreamServer.fromPlaylistUrl("http://h.example.com/list.m3u"))
    }
}
