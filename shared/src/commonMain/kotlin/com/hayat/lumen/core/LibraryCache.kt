package com.hayat.lumen.core

import kotlinx.io.buffered
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.io.decodeFromSource
import kotlinx.serialization.json.io.encodeToSink

/**
 * Saves a playlist's channels, films and series and TV guide to files on the phone, so the
 * app opens straight away and refreshes in the background (the TV app keeps them in its Room
 * database instead). Swift: `LibraryCache.shared.saveLive(library:path:)` etc.
 *
 * Writes go to `<path>.tmp` first and are then moved over the old file, so a crash mid-write
 * never leaves a broken cache. A file that can't be read (e.g. from an older app version)
 * just counts as no cache.
 */
@OptIn(ExperimentalSerializationApi::class)
object LibraryCache {
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private class GuideFile(val byChannel: Map<String, List<Programme>>)

    @Throws(Exception::class)
    fun saveLive(library: LiveLibrary, path: String) = write(path, LiveLibrary.serializer(), library)
    fun loadLive(path: String): LiveLibrary? = read(path, LiveLibrary.serializer())

    @Throws(Exception::class)
    fun saveVod(library: VodLibrary, path: String) = write(path, VodLibrary.serializer(), library)
    fun loadVod(path: String): VodLibrary? = read(path, VodLibrary.serializer())

    @Throws(Exception::class)
    fun saveGuide(guide: Guide, path: String) = write(path, GuideFile.serializer(), GuideFile(guide.byChannel))
    fun loadGuide(path: String): Guide? = read(path, GuideFile.serializer())?.let { Guide(it.byChannel) }

    private fun <T> write(path: String, serializer: KSerializer<T>, value: T) {
        val target = Path(path)
        val temp = Path("$path.tmp")
        SystemFileSystem.sink(temp).buffered().use { sink -> json.encodeToSink(serializer, value, sink) }
        SystemFileSystem.atomicMove(temp, target)
    }

    private fun <T> read(path: String, serializer: KSerializer<T>): T? {
        val file = Path(path)
        if (!SystemFileSystem.exists(file)) return null
        return runCatching {
            SystemFileSystem.source(file).buffered().use { source -> json.decodeFromSource(serializer, source) }
        }.getOrNull()
    }
}
