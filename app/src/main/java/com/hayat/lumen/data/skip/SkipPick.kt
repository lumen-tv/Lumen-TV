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
    /** One segment per kind: the first source that has it wins (sources are listed best first). */
    fun merge(sources: List<List<SkipSegment>>): List<SkipSegment> =
        SkipSegment.Kind.entries.mapNotNull { kind -> sources.firstNotNullOfOrNull { list -> list.firstOrNull { it.kind == kind } } }

    /**
     * The offer for [positionMs], or null. Intro and recap show from their start until just before
     * their end, wherever they fall (after a cold open too). Credits offer the next episode, only
     * when there is one, and only in the second half (a "credits" time early on is bad data).
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
                    val end = s.endMs ?: durationMs
                    if (positionMs >= s.startMs && positionMs < end) return SkipOffer(s.kind, s.startMs, null)
                }
            }
        }
        return null
    }

    /** Within this much of the end, skipping isn't worth it, so the button goes. */
    private const val END_MARGIN_MS = 2_000L
}
