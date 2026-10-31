package com.hayat.lumen.data.m3u

import com.hayat.lumen.util.UrlRedaction

/**
 * Gives every channel in one import a key that stays the same across refreshes,
 * so favourites, custom order and hidden state (Phase 2) survive a refresh.
 *
 * - `tvg:<tvg-id>` when the playlist provides one.
 * - Otherwise `h:<hash of name + URL without credentials>`, so a password change
 *   doesn't reshuffle everything.
 * - Duplicates within one import (common: SD/HD variants share a tvg-id) get the
 *   name appended, then a counter.
 *
 * One instance per import: it remembers the keys it has handed out.
 */
class StableKeys {
    private val used = HashSet<String>()

    fun keyFor(entry: M3uEntry): String {
        val name = normaliseName(entry.name)
        val base = entry.tvgId?.trim()?.lowercase()?.let { "tvg:$it" }
            ?: "h:${sha1("$name|${UrlRedaction.withoutCredentials(entry.url)}").take(16)}"
        if (used.add(base)) return base
        val withName = "$base|$name"
        if (used.add(withName)) return withName
        var n = 2
        while (!used.add("$withName#$n")) n++
        return "$withName#$n"
    }

    companion object {
        private val spaces = Regex("\\s+")

        fun normaliseName(name: String): String = name.trim().lowercase().replace(spaces, " ")

        /** SHA-1 of the UTF-8 bytes, as lowercase hex. Written out because iOS has no MessageDigest. */
        internal fun sha1(s: String): String = Sha1.hex(s.encodeToByteArray())
    }
}
