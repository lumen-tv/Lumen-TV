package com.hayat.lumen.core

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout

/** Swift: `LumenKt.makePlaylistLoader()`. Uses Apple's own networking (URLSession) under Ktor. */
fun makePlaylistLoader(): PlaylistLoader = PlaylistLoader(
    HttpClient(Darwin) {
        install(HttpTimeout) {
            connectTimeoutMillis = 15_000
            // Big lists from slow panels take a while.
            requestTimeoutMillis = 120_000
        }
        followRedirects = true
    },
)
