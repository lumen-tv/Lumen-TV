# Lumen

An IPTV player. This repo is the Android TV, Google TV and Fire TV app (Fire OS 8 or newer), written in Kotlin with Jetpack Compose for TV. Lumen is also on the App Store for iPhone and iPad, and there's a Mac download. Website: https://lumen-tv.github.io

Lumen is only a player. It comes with no channels, films or playlists, so you add a playlist or Xtream login from a provider you already use. It collects no data (see the [privacy policy](PRIVACY.md)).

## Get it

- **iPhone and iPad:** [Lumen TV Player on the App Store](https://apps.apple.com/gb/app/lumen-tv-player/id6830126774)
- **Mac:** download `Lumen.dmg` from the [Mac release](https://github.com/lumen-tv/Lumen-TV/releases/tag/mac)
- **Android TV, Google TV and Fire TV:** install it with the Downloader app (steps below)

## Features

- **Playlists:** add an M3U link or an Xtream login (server, username, password). If you paste a `get.php` link, it's loaded through the Xtream API, which gives proper categories.
- **Live TV:** categories on the left, channels on the right, with logos and what's on now.
- **Player:** full-screen live playback. Up/Down or CH+/CH- change channel, and OK shows an info overlay.
- **Favourites:** hold OK on a channel to favourite it. Lumen opens on Home, a grid of large channel cards showing the current programme, with a muted live preview on the focused card.
- **TV guide:** XMLTV guide from the playlist, a separate URL, or Xtream. Channels run down the side and the next 24 hours across. OK on a programme plays the channel.
- **Movies and series:** browse by category, pick up where you left off, and keep a My List.
- **Hiding things:** hold OK on a category to hide it, or use Live, then Categories, to switch categories and whole playlists on and off.
- **Looks:** dark theme, tvOS-style focus, tidied channel names, and built-in logo tiles for the main BBC, ITV, Channel 4 and Sky Sports channels.

## Installing on a TV

Lumen isn't on the Play Store, so you install it once with the free **Downloader** app. After that it updates itself.

1. On the TV, install **Downloader** (by AFTVnews).
2. Let it install apps. On Android TV or Google TV that's *Settings → Apps → Security & restrictions → Unknown sources → Downloader*. On Fire TV it's *Settings → My Fire TV → Developer options → Install unknown apps → Downloader*.
3. Open Downloader and enter `lumen-tv.github.io/get`. That always gives the newest version.
4. Choose **Install**.

When there's a new version, Home shows an "Update to …" button. The first time, Android asks you to allow Lumen to install updates, and after that each update is one click. Your playlists and favourites are kept.

### With adb

You need `adb` and wireless debugging turned on. [docs/SETUP.md](docs/SETUP.md) has the walkthrough.

```sh
adb connect <tv-ip>:<port>
adb -s <tv-ip>:<port> install -r lumen.apk
```

## Releasing

Bump `lumenVersion` in `app/build.gradle.kts` and merge to main. The Release workflow builds the APK, signs it with the private release key from the repo's Actions secrets, and publishes it as a GitHub Release called `v<version>` with `lumen.apk` attached. TVs pick it up within a few hours, or straight away with Live, then Refresh. Setting up the key is covered in [docs/RELEASING.md](docs/RELEASING.md).

## Building

You need JDK 17+ and the Android SDK (`platforms;android-37.0`).

```sh
./gradlew assembleRelease      # app/build/outputs/apk/release/app-release.apk
./gradlew installDebug         # build and install a debug build on the connected TV
./gradlew testDebugUnitTest    # unit tests
```

Judge smoothness on release builds, because debug Compose builds stutter on a Chromecast. Local builds (debug and release) are signed with the shared key in `keystore/`, so either installs over the other, but neither installs over a published release, which uses the private key.

## Layout

- `app/src/main/java/com/hayat/lumen/data`: Room database, M3U and Xtream import, TV guide (EPG)
- `app/src/main/java/com/hayat/lumen/playback`: the single shared ExoPlayer
- `app/src/main/java/com/hayat/lumen/ui`: the screens (Home, Live, Guide, Categories, Player, Movies, Series, Update) and shared components

## Privacy

Playlist logins stay on the device. Backups are turned off and credentials are never logged.

## Credits

- [Inter](https://rsms.me/inter/) font, SIL Open Font License (`third_party/inter`)
- UK channel logos from [tv-logo/tv-logos](https://github.com/tv-logo/tv-logos), Creative Commons ShareAlike. The logos are trademarks of their owners (`third_party/tv-logos`).
