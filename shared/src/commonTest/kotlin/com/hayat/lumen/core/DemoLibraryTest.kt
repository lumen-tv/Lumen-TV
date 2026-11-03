package com.hayat.lumen.core

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The static demo login on lumen-tv.github.io/demo: files instead of `player_api.php?action=`. */
class DemoLibraryTest {
    private val asked = mutableListOf<String>()

    private val files = mapOf(
        "/demo/player_api/account.json" to """{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8"]}}""",
        "/demo/player_api/get_live_categories.json" to """[{"category_id":"21","category_name":"Movies"}]""",
        "/demo/player_api/get_live_streams.json" to """[{"stream_id":1,"name":"Open Movie Channel","category_id":"21","epg_channel_id":"demo1","direct_source":"https://test.example/live.m3u8"}]""",
        "/demo/player_api/get_vod_categories.json" to """[{"category_id":"1","category_name":"Open Movies"}]""",
        "/demo/player_api/get_vod_streams.json" to """[{"stream_id":101,"name":"Big Buck Bunny (2008)","category_id":"1","container_extension":"mp4","direct_source":"https://archive.example/bbb.mp4"}]""",
        "/demo/player_api/get_series_categories.json" to "[]",
        "/demo/player_api/get_series.json" to "[]",
        "/demo/player_api/get_series_info-501.json" to """{"info":{"name":"Caminandes"},"episodes":{"1":[{"id":"5011","episode_num":1,"title":"Llama Drama","container_extension":"mp4","direct_source":"https://archive.example/e1.mp4"}]}}""",
    )

    private val loader = PlaylistLoader(
        HttpClient(MockEngine { request ->
            asked += request.url.encodedPath
            val body = files[request.url.encodedPath]
            if (body == null) respond("", HttpStatusCode.NotFound) else respond(body, HttpStatusCode.OK)
        }),
    )

    private val server = "https://lumen-tv.github.io/demo"

    @Test
    fun liveChannelsPlayTheirOwnLinks() = runTest {
        val live = loader.loadXtream(server, "demo", "demo")
        assertEquals("https://test.example/live.m3u8", live.channels.single().streamUrl)
        assertTrue(asked.none { "player_api.php" in it })
    }

    @Test
    fun filmsAndEpisodesPlayTheirOwnLinks() = runTest {
        val vod = loader.loadVod(server, "demo", "demo")
        assertEquals("Big Buck Bunny", vod.movies.single().title)
        assertEquals("https://archive.example/bbb.mp4", vod.movies.single().streamUrl)
        val info = loader.seriesInfo(server, "demo", "demo", "501")
        assertEquals("https://archive.example/e1.mp4", info.episodes.single().streamUrl)
        assertTrue("/demo/player_api/get_series_info-501.json" in asked)
    }

    @Test
    fun otherServersIgnoreDirectSource() = runTest {
        val other = PlaylistLoader(HttpClient(MockEngine { request ->
            val body = when (request.url.parameters["action"]) {
                "get_vod_streams" -> """[{"stream_id":5,"name":"Film","category_id":"1","container_extension":"mkv","direct_source":"https://elsewhere.example/x.mkv"}]"""
                "get_vod_categories" -> """[{"category_id":"1","category_name":"A"}]"""
                else -> "[]"
            }
            respond(body, HttpStatusCode.OK)
        }))
        val vod = other.loadVod("h.example.com", "u", "p")
        assertEquals("http://h.example.com/movie/u/p/5.mkv", vod.movies.single().streamUrl)
    }
}
