package com.hayat.lumen.core

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VodLoaderTest {

    private val answers = mapOf(
        "get_vod_categories" to """[{"category_id":"10","category_name":"TOP MOVIES ⁴ᴷ"},{"category_id":11,"category_name":"Empty"}]""",
        "get_vod_streams" to """[
            {"stream_id":5,"name":"4K-NF - Lupin (2021) (FR)","category_id":"10","stream_icon":"http://img/p.jpg","rating":"7.5","container_extension":"mkv","added":"1700000000"},
            {"stream_id":"6","name":"Plain Film","category_id":10,"rating":0,"container_extension":""},
            {"name":"no id"}
        ]""",
        "get_series_categories" to """[{"category_id":"20","category_name":"Drama"}]""",
        "get_series" to """[{"series_id":7,"name":"EN - Show (2019)","category_id":"20","cover":"http://img/c.jpg","backdrop_path":["","http://img/b.jpg"],"plot":"A plot","releaseDate":"2019-01-01","rating":"8"}]""",
        "get_vod_info" to """{"info":{"plot":"","description":"Thief.","duration_secs":"6000","backdrop_path":["http://img/bd.jpg"],"age":"12"},"movie_data":{}}""",
        "get_series_info" to """{"seasons":[],"info":{"cast":"A, B"},"episodes":{"2":[{"id":"902","episode_num":1,"title":"S2E1","container_extension":"mp4","info":{"duration_secs":1200}}],"1":[{"id":"802","episode_num":"2","container_extension":"mkv"},{"id":"801","episode_num":1}]}}""",
    )

    private val loader = PlaylistLoader(
        HttpClient(MockEngine { request ->
            val action = request.url.parameters["action"]
            respond(answers[action] ?: """{"user_info":{"auth":1}}""", HttpStatusCode.OK)
        }),
    )

    @Test
    fun loadsFilmsAndSeries() = runTest {
        val vod = loader.loadVod("h.example.com", "u", "p")
        assertEquals(listOf("Top Movies"), vod.movieCategories.map { it.title })
        assertEquals("4K", vod.movieCategories[0].quality)
        assertEquals(2, vod.movieCategories[0].count)
        val lupin = vod.movies[0]
        assertEquals("Lupin", lupin.title)
        assertEquals(2021, lupin.year)
        assertEquals("4K", lupin.quality)
        assertEquals(7.5, lupin.rating)
        assertEquals("http://h.example.com/movie/u/p/5.mkv", lupin.streamUrl)
        assertEquals("http://h.example.com/movie/u/p/6.mp4", vod.movies[1].streamUrl)
        assertNull(vod.movies[1].rating)
        val show = vod.series.single()
        assertEquals("Show", show.title)
        assertEquals(2019, show.year)
        assertEquals("http://img/b.jpg", show.backdropUrl)
    }

    @Test
    fun filmDetails() = runTest {
        val info = loader.movieInfo("h.example.com", "u", "p", "5")
        assertEquals("Thief.", info.plot)
        assertEquals(6000L, info.durationSecs)
        assertEquals("http://img/bd.jpg", info.backdropUrl)
        assertEquals("12", info.ageRating)
    }

    @Test
    fun seriesEpisodesInWatchingOrder() = runTest {
        val info = loader.seriesInfo("h.example.com", "u", "p", "7")
        assertEquals(listOf(1, 2), info.seasons)
        assertEquals(listOf("801", "802", "902"), info.episodes.map { it.id })
        assertEquals("http://h.example.com/series/u/p/802.mkv", info.episodes[1].streamUrl)
        assertEquals(1200L, info.episodes[2].durationSecs)
        assertEquals("A, B", info.cast)
    }
}
