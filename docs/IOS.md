# iPhone and iPad app: setup and install

The iOS app lives in `ios/`. Its screens are SwiftUI; loading playlists (Xtream, M3U), channel
names and keys come from the shared Kotlin code in `shared/`, which Xcode builds with Gradle into
`Shared.framework` before each build. iOS apps can only be built on a Mac, with Xcode.

## 1. Install Xcode and XcodeGen (once)

1. Install **Xcode** from the Mac App Store (free, about 15 GB). Open it once: accept the licence,
   and when it asks which platforms to download, tick **iOS**.
2. In Terminal: `brew install xcodegen`.
   XcodeGen builds `Lumen.xcodeproj` from `ios/project.yml`. The project file isn't in git: it's a
   huge machine-written file that clashes on every merge, so it's rebuilt instead.
3. Java and the Android command-line tools, which you already have for the TV app
   (`brew install openjdk@17` and `brew install --cask android-commandlinetools`). Xcode's build
   script (`ios/build-shared.sh`) finds them in Homebrew's folders by itself.

## 2. Sign in with your Apple ID (once)

Xcode → **Settings → Accounts** → **+** → Apple ID. This gives you a free **Personal Team**.
No $99 needed for now. What the free team means:

- An installed app **stops opening after 7 days**. Plug in and press Run again to renew it
  (your data in the app stays).
- At most 3 of your own apps on a device at a time.

### With the paid developer account ($99, Hayat has one since 2026-10-31)

- Installs no longer expire after 7 days (a year instead), and iCloud works: favourites, My List,
  where you stopped, hidden/renamed categories and the playlists themselves sync between your
  iPhone and iPad (logins through iCloud Keychain).
- Switch the project to the paid team once: find the **Team ID** at developer.apple.com →
  Account → Membership details, then put it in `ios/Config/Local.xcconfig`:
  `DEVELOPMENT_TEAM = ABCDE12345` (your own id), add a second line `LUMEN_ICLOUD = YES`, and run
  `./generate.sh` again. (Without that line the project has no iCloud, so it still builds with
  the free Personal Team while Apple confirms the membership; the app just doesn't sync.)
  In Xcode, Signing & Capabilities should now show your name **without** "(Personal Team)" and an
  **iCloud** capability (key-value storage). Xcode registers it with Apple by itself.
- Both devices must be signed in to the same Apple Account with iCloud on (Settings → your name
  → iCloud). Changes arrive within seconds to a few minutes.

## 3. Get the project and open it

```sh
cd ~/IPTV && git fetch && git checkout <branch> && git pull
cd ios && ./generate.sh && open Lumen.xcodeproj
```

Run `./generate.sh` again after every pull (it picks up new files).

## 4. First run on your iPhone or iPad

1. Plug the iPhone/iPad into the Mac with a cable. Unlock it and tap **Trust**.
2. **Turn on Developer Mode** on the device: Settings → Privacy & Security → **Developer Mode** → on.
   It restarts and asks you to confirm. (The option only appears after the device has been
   connected to Xcode once.)
3. In Xcode, click **Lumen** at the top of the left sidebar → target **Lumen** →
   **Signing & Capabilities** → **Team**: pick your name (Personal Team). Only needed the first
   time: run `./generate.sh` once afterwards and it remembers your team in
   `ios/Config/Local.xcconfig` (not committed).
   - If Xcode says the bundle id `com.hayat.lumen` isn't available, change
     `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` to e.g. `com.hayat.lumen.app`.
4. At the top of the Xcode window, choose your device from the device menu, then press **Run** (▶).
5. The first time, the phone refuses to open the app: Settings → General →
   **VPN & Device Management** → your Apple ID → **Trust**. Then open Lumen.

Later runs can go over Wi-Fi: Xcode → Window → Devices and Simulators → your device →
**Connect via network**.

No device to hand? Pick an iPhone or iPad **simulator** in the same device menu.

The **first** build after the shared code arrived takes several minutes: Gradle downloads Kotlin's
iOS compiler once. The step shows as "Build shared Kotlin code" in Xcode's build log (⌘9).

## 5. What to check

- Live TV → **Add playlist** (or Settings → Playlists → Add playlist): your Xtream server, username
  and password, or an M3U link. Add checks the login and loads the channels before saving. The
  login is stored in the iOS Keychain.
- Live TV lists the categories; pull down to refresh; search finds channels by name.
- Tap a channel: it plays full screen. Swipe up/down (or the buttons) to change channel, tap to
  show/hide the name. Your provider allows one connection, so the old channel stops first.
- Settings → Playlists: swipe left to remove, hold for Refresh.
- Channel pictures: every channel gets a coloured tile with its name (provider logos aren't used,
  so they all match). No bundled brand logos in the iPhone/iPad app.
- Favourites: hold a channel (or swipe it right) → Add to favourites; a blue star shows on it. They
  appear as big cards at the top of Live TV; tap one to watch and swipe to zap through favourites.
  **Edit** reorders (drag) or removes them. They survive refreshes, like on the TV.

- Movies and Series (Xtream logins): they load by themselves after the channels, from the same
  saved login. Rows of posters per category, See all (with search), film page (Play / Resume from
  … / Start over), series page (seasons, episodes, Resume S1 · E3). Films play with VLC, so .mkv
  and DTS audio work: tap for controls, double-tap left/right = 10 s, captions button = audio and
  subtitles, Next episode. Where you stopped is saved (Continue watching; hold to remove).

Channels, films and series load fresh each time the app starts (no saved copy on the phone yet).
The first build after VLC was added downloads it (Xcode → File → Packages if it says it's missing).

## App Store notes (for later)

What the iOS build does differently from Android, because of App Store rules:

- Ships with no channels, playlists or provider links ("Lumen doesn't provide any content").
- No built-in BBC/ITV/Channel 4/Sky logo tiles; ratings as plain text, no IMDb/Rotten Tomatoes marks.
- No self-updater: updates come from TestFlight or the App Store.
- `NSAllowsArbitraryLoads` is on because users type their own http servers; say so in the
  review notes.
- `PrivacyInfo.xcprivacy`: no tracking, no data collected. App Privacy label: "Data not collected".
- Reviewers get a legal test playlist (to be hosted on lumen-tv.github.io), never a real login.
