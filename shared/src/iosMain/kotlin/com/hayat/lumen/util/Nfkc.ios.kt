package com.hayat.lumen.util

import platform.Foundation.NSString
import platform.Foundation.precomposedStringWithCompatibilityMapping

@Suppress("CAST_NEVER_SUCCEEDS") // Kotlin strings bridge to NSString on Apple platforms.
internal actual fun nfkc(s: String): String = (s as NSString).precomposedStringWithCompatibilityMapping
