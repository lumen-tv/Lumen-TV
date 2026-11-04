package com.hayat.lumen.util

/**
 * Tidies provider category names for display: "TOP MOVIES ⁴ᴷ ³⁸⁴⁰ᴾ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ" → "Top Movies" + ["4K"].
 * Providers write tags in superscript letters; NFKC turns those back into plain ones first.
 * Display only, like [ChannelNames]: the stored name (and the user's rename) never changes.
 */
object CategoryNames {
    private val extras = Regex(
        """(?i)\b(3840P|4320P|DOLBY(\s+(AUDIO|ATMOS|VISION))?|ATMOS|DTS|HDR10\+?|MULTI[\s-]?SUBS?|SUBBED|SUBS?)\b""",
    )

    fun display(raw: String): DisplayName {
        val plain = nfkc(raw)
        return ChannelNames.display(plain.replace(extras, " "))
    }

    fun title(raw: String): String = display(raw).title
}

/** Unicode NFKC normalisation: `java.text.Normalizer` on Android, Foundation on iOS. */
internal expect fun nfkc(s: String): String
