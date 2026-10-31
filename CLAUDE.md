# Lumen: minimal IPTV player for Google TV

Personal, Apple/tvOS-inspired IPTV player. The spec is the handover doc (kept outside the repo).
The owner knows iOS/SwiftUI and is new to Android: explain Android-specific steps,
and comment where Compose differs from SwiftUI in a non-obvious way.

## Current phase

- **Phase 0: Setup.** Done, verified on the TV 2026-10-25.
- **Phase 1: Live basics.** Built (branch `phase-1-live`). Waiting on a real-TV check with the owner's M3U.
  - Add M3U source → Live (groups | channels) → full-screen player, Up/Down zapping, OK info overlay.
- **Favourites on launch.** Built (branch `claude/project-thread-pzzcm6`, on top of the guide/EPG work). Not yet checked on the TV.
  - Hold OK on a channel in Live to favourite it (★). Launch opens **Home**: favourites as large 16:9 cards with the logo
    (Coil), and after 1.2 s on a card a muted live preview plays inside it. OK opens the player, zapping through favourites.
    Hold OK on a card opens Move / Remove from favourites. Move: the card gets an accent outline, the arrows carry it
    through the grid (`GridMove`, tested), OK or Back puts it down and saves `favourites.position` (0.3.1).
    "All channels" opens Live.
- **TV guide grid.** Built (branch `claude/project-thread-0zjubh`, on top of favourites). Not yet checked on the TV.
  - "TV guide" on Home and Live opens a time grid: channels down, from the last half hour to 24 h ahead across.
    Left/Right = programmes (the window follows), Up/Down = channels at the same time, CH+/CH- = 5 rows, OK = play.
    Top button switches favourites/groups; "Guide settings" opens the old guide settings screen.
- **Hide categories and playlists.** Built (branch `claude/project-thread-xcw5xx`, on top of favourites). Not yet checked on the TV.
  - Hold OK on a category in Live to hide it. Live → **Categories** lists every category with a tick (OK toggles),
    a search, and Show all / Hide all (acting on just the search matches). OK on a playlist row hides the whole playlist.
- **Movies and series (VOD).** Merged into main (PR #10), checked on the TV 2026-10-28.
  - Home's top bar: Live TV · Movies · Series · My List. Each VOD tab: hero (backdrop, title, year, genre, plot) over rows:
    Continue watching (that tab only, not Home; wide 16:9 `ContinueCard`s with episode, time left and progress, 0.8.0),
    then the provider's categories (30 posters + "See all").
    **My List tab** (`ui/vod/MyListScreen.kt`, 0.8.0): films and series together, newest first (`observeMyListAll`), All /
    Films / Series pills (OK picks), a 6-column grid; hold OK removes. Replaced the My List rows on Movies/Series.
    Down into a poster row lands on its first poster; Up returns to the poster you left in that row (`RowFocus`, 0.7.1); the focused row always scrolls fully to the top of the list (`RowItem`, 0.7.2: the default nudge cropped the enlarged poster).
    Hold OK on a poster = add to / remove from My List; in Continue watching = remove. "See all" has Hide category; hidden ones come back at the
    bottom of the tab. Search (films + series) from the tab. Film page: Play / Resume from 42:10 / Start over / My List.
    Series page: Resume S1 · E3, seasons, episodes with progress. Player: OK pause, Left/Right 10 s (quick taps grow to 30 s, 1 min; holding ramps from 1 min/s to 20 min/s
    by hold time, see `SeekRamp`; "+12:30" shows while seeking),
    Down to the "Audio & Subtitles" button, then OK = audio/subtitles (only way: Up does nothing since 0.7.0); long track lists show the chosen track,
    the TV's language and English first, the rest behind "More languages" (`TrackPicks`, tested).
    Up next countdown at the end of an episode.
- **Over-the-air updates.** Merged into main (PR #11). Not yet checked on the TV.
  - Home shows "Update to 0.3.0" when GitHub Releases has a newer version → Update screen: what's new, Install update
    (first time: "Allow updates" opens Android's Install unknown apps switch), download progress, Android's confirm.
- **Chillio-style look (0.5.0).** Built on branch `claude/project-thread-p17iln`. Not yet checked on the TV (Hayat approved
  the Home and guide screenshots 2026-10-29). Colour instead of black, frosted glass, white focus, big VOD backdrops,
  IMDb / Rotten Tomatoes / age rating on film and series pages.
- **Guide in the player (0.6.0).** Built on branch `claude/project-thread-p17iln`. Not yet checked on the TV.
  - OK or Right (OK since 0.7.0; the info overlay still shows on zapping) while a channel plays opens a glass strip (`ui/player/PlayerGuide.kt`) with that channel's programmes for the next
    24 h. Left/Right = programmes, Up/Down (and CH+/-) = the guide of the channel above/below in the zapping list while the
    stream keeps playing (keeps the same time, `GuidePick`), OK = watch that channel, Back or 12 s idle = close.
    Programmes are plain time + title text, no boxes (Hayat: boxes looked selectable), selected = bright + white underline.
- **Settings page (0.4.0).** Merged (PR #15). Not yet checked on the TV.
  - "Settings" pill at the end of the top tabs (blue dot while an update waits; Home's hint line says so too; the old
    "Update to …" button on Home is gone). Menu left, section right: Playlists (OK = Refresh / Rename / Change link or
    login / Hide / Remove, plus Add playlist), TV guide, Live categories (OK hide, hold OK rename), Movie and Series
    categories (same), Ratings (the user's OMDb key), Updates, About. Live's Categories and the guide's Guide settings
    open it on their section.
- **iPhone/iPad app.** Started 2026-10-31 (branch `claude/project-thread-avhbdn`, PR #24). Setup in `docs/IOS.md`.
  - Phase 1 (ran on Hayat's iPhone 2026-10-31): SwiftUI app in `ios/` (XcodeGen `project.yml`, the .xcodeproj isn't
    committed): tabs, Settings → Test video playback.
  - Phase 2 (not yet run on a device): `shared/` Kotlin Multiplatform module. Add playlist (Xtream or M3U; get.php links
    stored as Xtream) loads channels via `PlaylistLoader`, saves only if that works; login in the Keychain, list in
    UserDefaults. Live TV: categories → channels (+ search), full-screen AVPlayer, swipe up/down zaps (350 ms debounce).
    Channels reload at each launch (no on-device database yet). Live TV checked on Hayat's iPhone 2026-10-31: works.
  - Name tiles + favourites (iOS only for now, Hayat 2026-10-31; not yet run): `ChannelArt` = always `NameTile` (Hayat
    2026-10-31: provider logos never fit, so none at all on iOS) (style A from the TV's Play-Store plan: palette colour by FNV-1a of the name, white name). Favourites:
    `PlaylistStore.favouriteKeys` (UserDefaults, playlist id → stable keys in order), hold/swipe a row to toggle,
    a card row at the top of Live TV, Edit sheet to reorder/remove, the player zaps within favourites.
  - Movies/Series (not yet run): `PlaylistLoader.loadVod/movieInfo/seriesInfo` (shared, tested), loaded after the channels
    for Xtream playlists. `ios/Lumen/Vod/`: tabs with Continue watching + category rows (30, See all grid), film and
    series pages, `VodPlayerView` on VLCKit (SPM package `tylerjonesio/vlckit-spm` 3.6, LGPL; AVPlayer can't do mkv/DTS),
    polled every 0.5 s. Progress in UserDefaults (`WatchProgress`, no stream URLs: they hold the password), saved every
    15 s and on leaving, 95% = finished, under 30 s not kept.
  - TV look (Hayat approved mockups 2026-10-31; not yet run): one app, layout by `lumenWide` (iPad + regular width).
    iPad: the TV's glass pill (search · Live TV · Movies · Series · My List · gear) + clock on top; iPhone: floating glass
    bar at the bottom. Custom tab container in `RootView` (tabs stay alive once opened). Live TV = `HomeView` (hero of the
    last-watched favourite over a wash of its colour, Watch / All channels, 2- or 4-wide favourite tiles) →
    `LiveChannelsView` (search, category pills, rows white while pressed). Movies/Series: title, Continue watching wide
    cards, poster rows (no hero: Hayat 2026-10-31, nothing drives it without focus; film/series pages keep backdrops).
    Search = round glass button beside the iPhone bar. iOS 26's top scroll edge effect is off (`hideTopScrollEdgeEffect`). My List tab (`MyListView`,
    `PlaylistStore.myList` in UserDefaults, All / Films / Series). `SearchView` = channels + films + series.
    Ratings as plain text (provider rating, age rating).
  - TV guide (not yet run): shared `PlaylistLoader.loadXtreamGuide/loadGuide` stream XMLTV through `XmltvReader`
    (hand-rolled, common Kotlin; tested in `GuideTest`), keeping now − 2 h … now + 36 h for the playlist's tvg-ids, into
    `Guide` (`nowNext`, `between`, `schedule`; epoch seconds). `.gz` guide files aren't read on iOS yet. Loaded at launch
    after the channels. Home hero now/next + tile progress, row "now" lines, player line. `GuideView`
    (Home → TV guide): a horizontal ScrollView holding the ruler + a vertical one (one direction per drag: Hayat found a
    free 2-axis pan felt like an overlay), opens on the current half hour; channel column pinned with
    `visualEffect` (render-time offset from its frame in `.scrollView(axis: .horizontal)`; a @State offset lagged a frame
    and let programmes slide over the tiles); tap = select (iPhone details card in a bottom
    `safeAreaInset`, above the tab bar / iPad panel with muted preview), double-tap = watch. No guide in the player.
  - Saved on the phone (not yet run): shared `LibraryCache` writes channels/guide/VOD as JSON to Caches/Lumen/<id>-live|guide|vod.json;
    launch shows them at once, then refreshes quietly (live + guide after 12 h, VOD after 24 h); failures keep old data.
  - Settings (not yet run): playlist page (rename, refresh everything, change Xtream login / M3U link: saved only if the
    channels load, blank password keeps the old; guide link; remove). Categories for Live/Movies/Series: tick = shown,
    search, Show all / Hide all on the matches, hold/swipe to rename (UserDefaults `hiddenCategories`/`categoryLabels`,
    keys `l:<name>`, `m:<id>`, `s:<id>`). Ratings: user's OMDb key in the Keychain (`Data/Ratings.swift`, checked first);
    film/series pages show Rotten Tomatoes %, IMDb + votes, age as plain text, provider score only without OMDb.
  - Player extras (not yet run): VOD remembers the audio/subtitle track name (`preferredAudioTrack`/`preferredSubtitleTrack`,
    matched on name then language word). Live TV: Picture in Picture (`Player/PictureInPicture.swift`, button + automatic
    on leaving the app); not for films (VLCKit has none).
  - iCloud sync (not yet run; Hayat bought the paid account 2026-10-31): `Data/CloudSync.swift` mirrors the UserDefaults
    JSON keys (playlists, favourites, watchProgress (merged, newest per item wins), myList, hiddenCategories,
    categoryLabels) to `NSUbiquitousKeyValueStore` (entitlement only in `project-icloud.yml`, used by generate.sh when
    Local.xcconfig has `LUMEN_ICLOUD = YES`: a Personal Team can't sign it); logins + OMDb key are synchronizable
    Keychain items (iCloud Keychain). A playlist arriving from the other device loads via `loadAll()`.
  - App icon: AB2 (Hayat 2026-10-31): soft out-of-focus blue/warm lights + glowing white L with a soft blue-white dot.
  - Not in Phase 1: Left sidebar and Right mini guide in the player (Phases 3/6), logos (Phase 4), settings/source editing (Phase 6).

## Decisions

- App name **Lumen**, package `com.hayat.lumen`.
- Device: Chromecast with Google TV **4K** (~2 GB RAM), at `192.168.4.72`. Connects via **Wireless debugging**
  (already paired with the laptop; the connect port changes after a reboot, so read it from the TV).
  Sources: **M3U + Xtream**. EPG: **separate XMLTV URL**.
- Accent **#0A84FF** (tvOS blue). Dark only. Font: Inter (bundled in `res/font`, OFL, license in `third_party/inter`).
- Versions (checked 2026-10-25, latest stable) are all in `gradle/libs.versions.toml`.
- AGP 9 "built-in Kotlin": no `org.jetbrains.kotlin.android` plugin. KSP 2.3.x runs Room's compiler.
- **DI: by hand.** `AppContainer` (on `LumenApp`) builds OkHttp, Room DB, repositories, `PlayerHolder`;
  composables get it via `LocalAppContainer`; ViewModels via `viewModel { Foo(container.x) }`.
- **Navigation 3**: the back stack is a `mutableStateListOf<Route>` in `ui/LumenRoot.kt`. Back pops; Back at root exits.
- **Room 2.8** (not Room 3, which is new; migration later is mostly renames). Schemas exported to `app/schemas`.
  **No destructive migration fallback**: every schema change needs a migration (prefer auto-migrations), so
  favourites etc. are never wiped.
- **Paging 3 deferred.** Lists are plain Room `Flow<List<…>>` of slim projections (`ChannelRow` has no URL).
  A 10k-channel group is ~2 MB. Revisit if a real playlist feels slow.
- **Import** (`data/LiveRepository.kt`): OkHttp stream → `M3uParser.entries()` (lazy `Sequence`) → batches of 500 rows
  under a new `generation` → one short transaction swaps generations. Old data stays if an import fails.
  Queries only read rows where `channel.generation == source.generation`.
- **Xtream** (`data/xtream/`): login = server + username + password, stored on `SourceEntity` (type `XTREAM`).
  Import uses `player_api.php` (account check, `get_live_categories`, `get_live_streams`, streamed with
  `android.util.JsonReader`) and builds `/live/<user>/<pass>/<id>.m3u8` (or `.ts` if HLS isn't allowed).
  A pasted `get.php?username=…&password=…` link is stored as Xtream automatically: the owner's provider
  blocks `get.php` (answers HTTP 884) but allows the API, which also gives proper groups.
- **EPG** (`data/epg/`): one guide URL per source = user-entered `epgUrl`, else the playlist's `url-tvg`
  (stored into `epgUrl` on import), else Xtream `xmltv.php` (built on the fly, never shown: it holds the password).
  `XmltvParser` streams `<programme>`s (gzip files detected by magic bytes); only channels whose
  `lower(tvgId)` is in the playlist, and only now−2 h … now+36 h, are stored in `programmes` under a new `batch`,
  then `epg_state.batch` is switched in one transaction (same idea as channel generations).
  Auto-update: at launch if older than 12 h, after adding a playlist, and with Live's Refresh. Settings: Live → TV guide.
  Reading: `EpgRepository.nowNextForGroup` (stored guide only), `nowNextForChannels`/`nowNext` (small lists:
  player, focused row, favourites) fall back to Xtream `get_short_epg` per channel, cached in memory.
  No name matching yet: channels without a tvg-id get no guide.
- M3U entries whose URL contains `/movie/` or `/series/` are skipped (VOD comes via Xtream in Phase 5).
- **Stable keys** (`data/m3u/StableKeys.kt`): `tvg:<id>`, else a hash of name + URL with credentials stripped.
  Duplicates get `|name`, then `#n`. Phase 2 user state must key on `(sourceId, stableKey)`, **not** row ids:
  channel ids change on every refresh.
- Credentials: `util/UrlRedaction.kt`. Error messages show `hostOnly(url)`; never log raw URLs.
- Cleartext http allowed app-wide (`res/xml/network_security_config.xml`): IPTV is mostly http.
- **Favourites**: `favourites` table (DB v3, auto-migration from v2; v2 is the guide tables), keyed `(sourceId, stableKey)`, ordered by `position`.
  Joined to the current generation's channels, so a favourite missing from the playlist hides and returns if it comes back.
  Removing a source deletes its favourites.
- **Hidden** (DB v4, auto-migration from v3): `hidden_groups` keyed `(sourceId, groupName)` (survives refreshes, like
  favourites) and `sources.hidden`. `ChannelDao.observeGroups` (Live, guide grid) leaves both out. Favourites in a hidden
  category still show on Home; a hidden playlist hides its favourites, skips Refresh and guide updates. Guide imports skip
  channels in hidden categories unless they're favourites; leaving Categories reloads the guide for anything shown again.
- **Home preview** (`ui/home/HomeScreen.kt`): uses the one shared ExoPlayer (one decoder, one provider connection) on a
  TextureView (a SurfaceView ignores the card's focus scale and clip). OK on the previewed card hands the running stream to
  the player, so it starts without re-buffering. `PlayerHolder.acquire(owner)`/`stop(owner)`: stop only acts for the
  latest owner, because Home and the player overlap during the screen fade.
- **Logos**: Coil 3 (`AppContainer.images`, via the app's OkHttp, memory cache 10%). Shown through `ChannelArt`/`ChannelLogo`
  (`ui/components/ChannelArt.kt`) on Home cards, Live rows and the player overlay.
- **Apple TV look**: `ChannelArt` fills its box with the logo's own colour (solid logo border → that colour, and the logo is
  drawn bigger so it blends; transparent logo → a deep wash of its main colour; grey/white logos → neutral). Colours are
  computed once per URL from a 24×24 sample (bitmaps loaded with `allowHardware(false)`, size 480).
  `LumenCard`: 16 dp corners, focus = 1.1× lift + dark shadow + one light sheen sweep, no dimming.
  Home: the focused favourite is the hero (clean name, quality tag, now/next) over a wash of its colour; cards below.
- **Built-in brand tiles** (`ui/components/BrandLogos.kt`): the main BBC, ITV, Channel 4 family and Sky Sports channels
  ignore the provider's logo and show a bundled logo (`res/drawable-nodpi/logo_*.png`, from tv-logo/tv-logos, see
  `third_party/tv-logos`) on a solid brand-colour tile. Matched by cleaned name with regexes (tests in `BrandLogosTest`).
- **Home layout**: hero on top, favourites in a 4-column grid below (two rows visible, so 8 favourites without scrolling).
  Cards have no label underneath: the hero shows the focused channel's name.
- **Display names**: `util/ChannelNames.display()` strips country prefixes, quality tags (→ one "4K"/"HD" chip) and
  symbols, and title-cases all-caps names (keeping known acronyms). Display only: stored names never change.
- **Guide grid** (`ui/guide/GuideScreen.kt`): one focusable box handles the D-pad (not one focusable per cell), keeping an
  `anchor` time so Up/Down stays at the same time. Cells are placed with `offset { }` from an animated window position, so
  moving the window relayouts without recomposing. Rows are slots from `GuideSlots.build` (gaps = "No guide info", cut at
  half hours). Schedules load via `EpgRepository.schedule` for the rows on screen ± a margin, in blocks of 20 rows.
- **Player** (`playback/PlayerHolder.kt`): one ExoPlayer, created lazily, released in `MainActivity.onStop`.
  Starts after 1 s of buffer. OkHttp data source (follows http→https redirects).
  Zapping is debounced 350 ms, and the old stream is stopped at once (providers often allow 1 connection).
  Up = previous in list, Down = next; CH+/CH- keys = next/previous.
- **Renames** (DB v6, auto-migration from v5): `renamed_groups (sourceId, groupName, label)` and
  `renamed_vod_categories (sourceId, kind, categoryId, label)`. Display only: queries return the provider's name as the key
  (`GroupRow.name`, `PlayableChannel.groupName`) plus `label`/`groupLabel` to show; VOD rows' `name` is already the label.
  Saving a blank name or the provider's own removes the rename. Playlist renames just change `sources.name`.
- **Changing a playlist's link/login** (`LiveRepository.changeConnection`): saves it, refreshes, and puts the old one back if
  the import fails. The old M3U link is never shown (it may hold credentials); a blank Xtream password keeps the old one.
- **Settings store** (`data/settings/Preferences.kt`): SharedPreferences for non-playlist settings (the OMDb key, which is
  the user's own and must never be committed or logged; `data/ratings/OmdbClient` checks it).
- **VOD** (`data/vod/`, DB v5, auto-migration from v4): Xtream only. `movies`, `series`, `vod_categories` stored under
  `sources.vodGeneration` (same swap idea as channels), ~35k films + 9k series on the owner's provider.
  Loaded in the background at launch if older than 24 h, after adding a playlist, and with Live's Refresh.
  Film details (`get_vod_info`) and episodes (`get_series_info`) are fetched on demand, cached in memory (LRU), not stored.
  User state keyed on provider ids (survive refreshes): `watch_progress` (finished at 95%, saved every 15 s, on pause and
  on leaving; under 30 s isn't saved), `my_list`, `hidden_vod_categories`. `NextUp.pick` chooses a series' Play episode.
  Display names: `util/VodNames` strips `4K-NF - ` prefixes and `(2021) (FR)` suffixes. Subtitles use Media3's
  `SubtitleView` (media3-ui) inside an `AndroidView`. Stream URLs: `/movie/u/p/<id>.<ext>`, `/series/u/p/<id>.<ext>`.
- **Updates** (`data/update/`): version lives in `app/build.gradle.kts` as `lumenVersion`; `versionCode` is derived
  (major·10000 + minor·100 + patch, so 0.2.0 = 200; it was 2 before). `.github/workflows/release.yml` runs on every push
  to main: if release `v<lumenVersion>` doesn't exist, it builds `assembleRelease` and publishes it with `lumen-<v>.apk`
  and the commit titles since the last tag as notes. **To ship an update, bump `lumenVersion` in the PR.**
  The app checks `api.github.com/repos/lumen-tv/Lumen-TV/releases/latest` (public repo, no token) at launch, when Home shows
  (at most every 6 h) and with Live's Refresh. Install streams the APK into a `PackageInstaller` session (no file, no
  FileProvider), result via `InstallResultReceiver`; `USER_ACTION_NOT_REQUIRED` is requested, so once Lumen is its own
  installer of record later updates may skip the confirm screen. Needs `REQUEST_INSTALL_PACKAGES` + the user's one-time
  "Install unknown apps" switch. Android rejects an update with a different signing key, so never change the key.
- **Public release (Route 1, from 0.3.0)**: distributed on GitHub Releases only (no Play Store yet). Releases are
  signed with a **private key** (`LUMEN_KEYSTORE*` Actions secrets, set up per `docs/RELEASING.md`; the workflow fails
  without them). The asset is always `lumen.apk`, so `releases/latest/download/lumen.apk` is a stable link for the
  Downloader app. Repo moved 2026-10-28 from hayatayubi/IPTV to the **lumen-tv** organisation as `lumen-tv/Lumen-TV`
  (Hayat didn't want their name in links). Public page: https://lumen-tv.github.io (repo `lumen-tv/lumen-tv.github.io`),
  `/get` forwards to the newest APK. `PRIVACY.md` = privacy policy. The brand logo tiles stay in the public build (Hayat's choice
  2026-10-28; they'd have to go for Google Play).
- **Shared Kotlin** (`shared/`, Kotlin Multiplatform: android + iosArm64 + iosSimulatorArm64 + linuxX64 for tests only):
  `M3uParser`, `StableKeys` (own `Sha1`), `UrlRedaction` (own `SimpleUri`, matched against `java.net.URI` by
  `UrlRedactionMatchesUriTest`: stable keys hash its output, so it must never drift), `ChannelNames`, `CategoryNames`
  (NFKC via expect/actual), `VodNames`, keeping their old packages; the Android app uses them as before. `core/` =
  iPhone-only for now: `PlaylistLoader` (Ktor + kotlinx.serialization, `XtreamServer`, `XtreamApi`), exported to Swift as
  `Shared.framework` (`LumenKt.makePlaylistLoader()`, suspend = Swift `async throws`, call from the main actor).
  Tests: `./gradlew :shared:testAndroidHostTest :shared:linuxX64Test` (native run catches Kotlin/Native regex
  differences: a negated class with `\p{…}` ignores its other members, so `symbols` uses a lookahead).
  Xcode runs `ios/build-shared.sh` → `:shared:embedAndSignAppleFrameworkForXcode` (finds Homebrew Java/Android SDK).
  Cloud sessions can compile the iOS klibs (`:shared:compileKotlinIosArm64`) but can't link the framework or build Swift.
- **iOS** (`ios/`): SwiftUI, iOS 18+, iPhone + iPad, bundle id `com.hayat.lumen`. Built on Hayat's Mac with Xcode
  (cloud sessions are Linux: they can't build or check Swift). Hayat has a paid developer account since 2026-10-31 (team id in the uncommitted
  `ios/Config/Local.xcconfig`). App Store rules for the iOS build: no bundled content or provider links, no `BrandLogos` tiles, ratings as plain
  text, no self-updater, http allowed via ATS (`NSAllowsArbitraryLoads`), passwords in the Keychain, `PrivacyInfo.xcprivacy`.
- Shared debug keystore in `keystore/`: signs debug builds and local release builds, so cloud and laptop builds install
  over each other. It can't install over a published (privately signed) release, or the reverse.
- Backups disabled (`allowBackup=false` + `data_extraction_rules.xml`): credentials stay on the device.
- UI components (`ui/components`):
  - `LumenListItem`: focused row turns light with dark text.
  - `LumenButton`.
  - `LumenTextField`: the keyboard opens only on OK, not on focus.
  - `Monogram`: fallback tile.
  - `LumenCard`: poster tile for Phase 4.
- **Look (0.5.0, Chillio/Apple TV inspired; Hayat keeps Inter, wants colour not black)**: screens sit on `Ambient`
  (`ui/components/Glass.kt`: dark base + a cool glow top left, tinted by the focused channel's logo colour on Home and in
  the guide, and a warm glow bottom right; `Modifier.ambient()` for Row/Column roots). Bars, buttons, panels =
  `Modifier.glass()` (white 7–13% fill + 10% edge; real blur is too heavy for the 2 GB TV); dark glass over video.
  Focus = solid white with dark text; blue only for ticks, LIVE, the update dot. `TopTabs` = one centred glass pill
  (search icon · Live TV · Movies · Series · settings gear) + `Clock` on the right; `Tab.SEARCH`/`Tab.SETTINGS` open
  screens. `LumenButton(primary = true)` = white Play pill; `icon =` vector icons in `res/drawable/ic_*.xml` (Material
  Icons, Apache 2.0). Home: hero, then "Favourites" + hint + All channels / TV guide, then the grid. Guide: glass
  details panel with the focused live channel previewing muted on the right (`ui/components/LivePreview.kt`, shared with
  Home). VOD: full-screen backdrops, heart = My List. Category names are tidied for display by
  `util/CategoryNames` (NFKC first: providers write tags in superscript letters like ᴰᴼᴸᴮʸ). The fanned-poster category
  tiles were dropped (0.6.2: names cut off, posters over the text). Up into `TopTabs` always lands on the open tab.
- **Ratings**: `data/ratings/OmdbClient.ratings(key, title, year, series)` (OMDb `t=`/`y=`/`type=`), in-memory LRU, null
  without the user's key. Shown big, as in Chillio, by `RatingsPanel` (drawn tomato/splat + "Tomatometer", IMDb box + votes, age box): its own
  "Ratings" row under the film page's buttons, at the right of the series page's buttons; the provider's
  ★ shows only when OMDb has nothing. Common Sense Media has no free API (paid licence), so the age rating stands in.
- Screenshots in cloud sessions: Robolectric 4.17 + Roborazzi render screens with test data (kept out of the repo:
  needs `robolectric.dependency.repo.url` = the Google Maven mirror, `roborazzi.test.record=true`, the compose clock
  frozen so the 1.2 s live preview never starts). Coil images don't load there.
- Motion: `LumenMotion.focus()` = 180 ms ease-out. Safe area: `SafeArea` (48 dp × 27 dp).

## Known issues

- Not verified on device yet (Phase 1): Back priority between `BackHandler` in the player and NavDisplay;
  focus return to the last channel after leaving the player.
- `type=m3u` Xtream URLs have no group/logo attributes. Moot for `get.php` links now: they go through the Xtream API.
- EPG import and `get_short_epg` not verified on a real provider yet.
- Xtream JSON parsing has no unit tests (android.util.JsonReader is a stub on the JVM); it is checked on the TV.
  The VOD parsers were checked once (2026-10-27) against a saved copy of the owner's provider lists with Gson's
  identical JsonReader, in a throwaway test.
- VOD audio: DTS tracks have no decoder on the Chromecast (no FFmpeg extension), so such films may be silent; pick
  another track with Up. Not verified on the TV yet.
- tv-material Card/Surface scale animation timing isn't configurable. Revisit in Phase 4.
- Placeholder banner/icon.
- Home cards show the guide's current programme and progress under the name when the guide has one.

## Working notes

- Build: `./gradlew assembleDebug` · Tests: `./gradlew testDebugUnitTest :shared:testAndroidHostTest :shared:linuxX64Test` · Lint: `./gradlew lintDebug`.
- **Judge smoothness only on release builds.** Debug Compose builds are visibly janky on the Chromecast; release
  (`./gradlew assembleRelease`, R8 + same shared key, installs over debug) was confirmed smooth on the TV.
  Startup profile: the libraries ship theirs, and `app/src/main/baseline-prof.txt` (0.7.0) adds wildcard rules for all of
  Lumen's own code; profileinstaller (a transitive dependency) applies them after install/update, in the background.
  After sideloading, `adb shell cmd package compile -f -m speed-profile com.hayat.lumen` applies them right away.
- Typing a URL on the TV: open the field with OK, then `adb shell "input text 'http://…'"` from the laptop
  (inner single quotes stop the device shell from eating `&`).
- Cloud sessions: Maven Central rate-limits (429) the shared egress IP. Use a Gradle init script in
  `~/.gradle/init.d/` that puts `https://maven-central.storage-download.googleapis.com/maven2/` first.
  Never put it in the repo.
- Never commit or log playlist URLs or credentials (the owner's test URL included).
