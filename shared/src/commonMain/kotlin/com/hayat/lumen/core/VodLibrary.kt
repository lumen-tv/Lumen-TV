package com.hayat.lumen.core

import kotlinx.serialization.Serializable

/** A playlist's films and series (Xtream only), ready to show in the iPhone app's tabs. */
@Serializable
class VodLibrary(
    val movieCategories: List<VodCategory>,
    val movies: List<Movie>,
    val seriesCategories: List<VodCategory>,
    val series: List<Series>,
)

@Serializable
class VodCategory(
    val id: String,
    /** The provider's name. */
    val name: String,
    /** Tidied by `CategoryNames`: "TOP MOVIES ⁴ᴷ" → "Top Movies". */
    val title: String,
    /** "4K" when the provider's name says so. */
    val quality: String?,
    val count: Int,
)

@Serializable
class Movie(
    val id: String,
    val name: String,
    /** Tidied by `VodNames`: "4K-NF - Lupin (2021) (FR)" → "Lupin". */
    val title: String,
    val year: Int?,
    val quality: String?,
    val categoryId: String,
    val posterUrl: String?,
    /** Out of 10, when the provider has one. */
    val rating: Double?,
    /** Holds the login: never log or show it. */
    val streamUrl: String,
    /** Epoch seconds the provider added it, for "newest first". */
    val added: Long?,
)

@Serializable
class Series(
    val id: String,
    val name: String,
    val title: String,
    val year: Int?,
    val categoryId: String,
    val posterUrl: String?,
    val backdropUrl: String?,
    val plot: String?,
    val genre: String?,
    val rating: Double?,
)

/** `get_vod_info`. Every field is optional: panels fill in what TMDB gave them. */
class MovieInfo(
    val plot: String?,
    val genre: String?,
    val director: String?,
    val cast: String?,
    val durationSecs: Long?,
    val releaseDate: String?,
    val backdropUrl: String?,
    val ageRating: String?,
)

class SeriesInfo(
    /** Season numbers that have episodes, in order. */
    val seasons: List<Int>,
    /** In watching order. */
    val episodes: List<Episode>,
    val cast: String?,
    val director: String?,
    /** The show's TMDB id (`info.tmdb`), used to look up intro times. */
    val tmdbId: String? = null,
)

class Episode(
    val id: String,
    val season: Int,
    val episode: Int,
    val title: String?,
    val durationSecs: Long?,
    val imageUrl: String?,
    val plot: String?,
    /** Holds the login: never log or show it. */
    val streamUrl: String,
)
