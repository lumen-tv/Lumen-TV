package com.hayat.lumen.core

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.HttpTimeout
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GuideTest {

    // 2026-10-31 19:38 UTC
    private val now = XmltvReader.parseTime("20261031193800 +0000")!!

    private val xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE tv SYSTEM "xmltv.dtd">
        <tv generator-info-name="test">
          <channel id="BBCOne.uk"><display-name>BBC One</display-name></channel>
          <programmes-note>not a programme</programmes-note>
          <programme start="20261031193000 +0000" stop="20261031200000 +0000" channel="BBCOne.uk">
            <title lang="en">EastEnders</title>
            <desc lang="en">Albert &amp; Sonia’s choice — café &#233;&#x1F600;.</desc>
          </programme>
          <programme start='20261031210000 +0100' stop='20261031223000 +0100' channel='bbcone.uk'>
            <title><![CDATA[Love Island & Friends]]></title>
          </programme>
          <programme start="20261031183000 +0000" stop="20261031193000 +0000" channel="bbcone.uk"><title>The One Show</title></programme>
          <programme start="20261028090000 +0000" stop="20261028100000 +0000" channel="bbcone.uk"><title>Too old</title></programme>
          <programme start="20261031193000 +0000" stop="20261031200000 +0000" channel="other.uk"><title>Not ours</title></programme>
          <programme start="20261031200000 +0000" stop="20261031193000 +0000" channel="bbcone.uk"><title>Backwards</title></programme>
          <programme start="20261031203000 +0000" stop="20261031210000 +0000" channel="bbcone.uk"></programme>
        </tv>
    """.trimIndent()

    private fun read(text: String, pieceSize: Int): Guide {
        val reader = XmltvReader(setOf("bbcone.uk"), now - 2 * 3600, now + 36 * 3600)
        val bytes = text.encodeToByteArray()
        var i = 0
        while (i < bytes.size) {
            val n = minOf(pieceSize, bytes.size - i)
            reader.feed(bytes.copyOfRange(i, i + n), n)
            i += n
        }
        return reader.finish()
    }

    @Test
    fun readsProgrammesWhateverThePieceSize() {
        for (size in listOf(1, 2, 3, 7, 64, 100_000)) {
            val guide = read(xml, size)
            val list = guide.schedule("BBCOne.UK")
            assertEquals(listOf("The One Show", "EastEnders", "Love Island & Friends"), list.map { it.title }, "piece $size")
            assertEquals("Albert & Sonia’s choice — café é😀.", list[1].description, "piece $size")
            assertEquals(1, guide.channelCount)
        }
    }

    @Test
    fun offsetsAreApplied() {
        val love = read(xml, 64).schedule("bbcone.uk").last()
        assertEquals(XmltvReader.parseTime("20261031200000 +0000"), love.start)
        assertEquals(90 * 60L, love.stop - love.start)
    }

    @Test
    fun nowAndNext() {
        val guide = read(xml, 64)
        val nn = guide.nowNext("bbcone.uk", now)!!
        assertEquals("EastEnders", nn.now?.title)
        assertEquals("Love Island & Friends", nn.next?.title)
        assertEquals(8.0 / 30, nn.now!!.progress(now), 1e-9)
        assertNull(guide.nowNext("missing", now))
        assertNull(guide.nowNext(null, now))
        assertEquals(listOf("EastEnders"), guide.between("bbcone.uk", now, now + 60).map { it.title })
    }

    @Test
    fun parsesTimes() {
        assertEquals(0L, XmltvReader.parseTime("19700101000000 +0000"))
        assertEquals(1_793_048_400L, XmltvReader.parseTime("20261026220000 +0100"))
        assertEquals(XmltvReader.parseTime("202610262100 +0000"), XmltvReader.parseTime("20261026220000 +0100"))
        assertEquals(951_782_400L, XmltvReader.parseTime("20000229"))
        assertNull(XmltvReader.parseTime("2026"))
        assertNull(XmltvReader.parseTime("20261340000000"))
    }

    @Test
    fun utf8Boundaries() {
        val bytes = "a€😀".encodeToByteArray() // 1 + 3 + 4 bytes
        assertEquals(8, XmltvReader.completeUtf8Length(bytes))
        assertEquals(1, XmltvReader.completeUtf8Length(bytes.copyOf(2)))
        assertEquals(1, XmltvReader.completeUtf8Length(bytes.copyOf(3)))
        assertEquals(4, XmltvReader.completeUtf8Length(bytes.copyOf(4)))
        assertEquals(4, XmltvReader.completeUtf8Length(bytes.copyOf(7)))
    }

    private fun loader(handler: (url: String) -> Pair<HttpStatusCode, ByteArray>) = PlaylistLoader(
        HttpClient(MockEngine { request ->
            val (status, body) = handler(request.url.toString())
            respond(body, status)
        }) { install(HttpTimeout) },
    )

    @Test
    fun loadsTheXtreamGuide() = runTest {
        var asked = ""
        val guide = loader { url -> asked = url; HttpStatusCode.OK to xml.encodeToByteArray() }
            .loadXtreamGuide("cf.example.com:8080", "user", "p/s", listOf("BBCOne.uk", " "), now)
        assertEquals("http://cf.example.com:8080/xmltv.php?username=user&password=p%2Fs", asked)
        assertEquals(3, guide.schedule("bbcone.uk").size)
    }

    @Test
    fun explainsFailures() = runTest {
        val gz = byteArrayOf(0x1f, 0x8b.toByte(), 8, 0)
        val e1 = assertFailsWith<LoadException> { loader { HttpStatusCode.OK to gz }.loadGuide("http://epg.example.com/g.xml.gz?k=secret", listOf("a"), now) }
        assertTrue(".gz" in e1.message!!)
        assertTrue("secret" !in e1.message!!)
        val e2 = assertFailsWith<LoadException> { loader { HttpStatusCode.Forbidden to ByteArray(0) }.loadGuide("http://epg.example.com/g.xml", listOf("a"), now) }
        assertTrue("403" in e2.message!!)
        val e3 = assertFailsWith<LoadException> { loader { HttpStatusCode.OK to "<html>nope</html>".encodeToByteArray() }.loadGuide("http://epg.example.com/g.xml", listOf("a"), now) }
        assertTrue("couldn't read" in e3.message!!)
        assertFailsWith<LoadException> { loader { HttpStatusCode.OK to ByteArray(0) }.loadGuide("http://epg.example.com/g.xml", listOf(" "), now) }
    }
}
