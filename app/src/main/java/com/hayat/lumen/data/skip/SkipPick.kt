package com.hayat.lumen.data.skip

/** What the player offers right now: "Skip intro", "Skip recap" or "Next episode". */
data class SkipOffer(val kind: SkipSegment.Kind, val segmentStartMs: Long, /** Where Skip jumps to; null for Next episode. */ val targetMs: Long?) {
    val label: String
        get() = when (kind) {
            SkipSegment.Kind.INTRO -> "Skip intro"
            SkipSegment.Kind.RECAP -> "Skip recap"
            SkipSegment.Kind.CREDITS -> "Next episode"
        }
}

object SkipPick {
    /**
     * One segment per kind: the first source that has it wins (sources are listed best first).
     * For credits, a source that gives their end wins, because only then is their length known.
     */
    fun merge(sources: List<List<SkipSegment>>): List<SkipSegment> =
        SkipSegment.Kind.entries.mapNotNull { kind ->
            val all = sources.mapNotNull { list -> list.firstOrNull { it.kind == kind } }
            if (kind == SkipSegment.Kind.CREDITS) all.firstOrNull { it.endMs != null } ?: all.firstOrNull() else all.firstOrNull()
        }

    /**
     * When "Next episode" appears. The databases time the credits on the streaming service's copy,
     * and a provider's file often runs longer or shorter, so a start time counted from the beginning
     * lands minutes off. Counted back from the end of this file it doesn't: the credits' length
     * (when the database gives their end) is subtracted from this file's length. Either way it
     * never appears before the last [CREDITS_LATEST] of the file, so a wrong time can't show it
     * while the story is still going.
     */
    fun creditsStart(credits: SkipSegment, durationMs: Long): Long {
        val length = credits.endMs?.let { it - credits.startMs }?.takeIf { it in 5_000..CREDITS_LATEST }
        val start = if (length != null) durationMs - length else credits.startMs
        return maxOf(start, durationMs - CREDITS_LATEST)
    }

    /**
     * The offer for [positionMs], or null. Intro and recap show from their start until just before
     * their end, wherever they fall (after a cold open too). Credits offer the next episode, only
     * when there is one, timed back from the end of the file ([creditsStart]); a "credits" time in
     * the first half is bad data and ignored.
     */
    fun at(segments: List<SkipSegment>, positionMs: Long, durationMs: Long, hasNext: Boolean): SkipOffer? {
        for (s in segments) {
            when (s.kind) {
                SkipSegment.Kind.INTRO, SkipSegment.Kind.RECAP -> {
                    val end = s.endMs ?: continue
                    if (durationMs > 0 && end >= durationMs) continue
                    if (positionMs >= s.startMs && positionMs < end - END_MARGIN_MS) return SkipOffer(s.kind, s.startMs, end)
                }
                SkipSegment.Kind.CREDITS -> {
                    if (!hasNext || durationMs <= 0 || s.startMs < durationMs / 2) continue
                    if (positionMs >= creditsStart(s, durationMs)) return SkipOffer(s.kind, s.startMs, null)
                }
            }
        }
        return null
    }

    /** Within this much of the end, skipping isn't worth it, so the button goes. */
    private const val END_MARGIN_MS = 2_000L
    /** "Next episode" shows at most this long before the end (Hayat: three minutes early felt wrong). */
    const val CREDITS_LATEST = 120_000L
}
