package com.hayat.lumen.util

// Linux is only a test target (see shared/build.gradle.kts) and has no Unicode normaliser.
internal actual fun nfkc(s: String): String = s
