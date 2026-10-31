package com.hayat.lumen.core

import kotlinx.serialization.Serializable

/** A playlist's live channels, ready to show: what the iPhone app lists in Live TV. */
@Serializable
class LiveLibrary(
    /** In the provider's order (Xtream), or first-seen order (M3U). Only categories with channels. */
    val categories: List<LiveCategory>,
    val channels: List<LiveChannel>,
    /** The playlist's guide URL (`url-tvg`), when an M3U names one. */
    val epgUrl: String?,
    /** Entries that couldn't be read and were left out. */
    val skipped: Int,
)

@Serializable
class LiveCategory(
    /** The provider's name, kept as the key (renames and hiding key on it, like on Android). */
    val name: String,
    /** Tidied for display by `CategoryNames`. */
    val title: String,
    val channelCount: Int,
)

@Serializable
class LiveChannel(
    /** `StableKeys` key: the same across refreshes, for favourites later. */
    val key: String,
    /** The provider's name. */
    val name: String,
    /** Tidied for display by `ChannelNames`: "UK: BBC ONE HD" → "BBC One". */
    val title: String,
    /** "4K" or "HD", or null. */
    val quality: String?,
    val categoryName: String?,
    val logoUrl: String?,
    /** Holds the login: never log or show it. */
    val streamUrl: String,
    val tvgId: String?,
    val number: Int?,
)

/** A reason the playlist couldn't be loaded, worded for the user. Swift reads it as the error's message. */
class LoadException(message: String, cause: Throwable? = null) : Exception(message, cause)
