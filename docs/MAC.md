# Mac app: build, sign and ship the DMG

The Mac app is the iPhone/iPad app's SwiftUI screens built for macOS (target **LumenMac** in
`ios/project.yml`), plus a few Mac-only files in `ios/Mac/`:

- `MacShims.swift`: Mac stand-ins for the UIKit names the shared screens use (`UIImage` is
  `NSImage`; keeping the display awake while video plays; no haptics or screen rotation).
- `MacApp.swift`: one window, the menu bar (⌘F search, ⌘1–⌘4 tabs, ⌘, Settings, Check for
  Updates), the players filling the window (`PlayerStage`), and the player keys.
- `MacVideo.swift`: the video layer, AirPlay button and the Mac's volume for the players.
- `MacUpdates.swift`: checks the GitHub release tagged `mac` and offers the new DMG.
- `MacHover.swift`: posters and cards lift under the pointer, buttons brighten, sideways rows get < > arrows.
- `MacMiniPlayer.swift`: the mini player, a floating panel the running player moves into.
- `MacPlayback.swift`: what the showing player can do, for the mini player and the Playback menu.
- `MacPlayerInput.swift`: clicks, pinch and two-finger scrolling over the picture.

The rest is shared, so a feature added to the iPhone app is on the Mac too. Where the two differ,
the screens call one helper (`ios/Lumen/Theme/Platform.swift`: `urlKeyboard()`, `navBar(_:)`,
`fullWindowCover`, `macPlayerKeys`…) or use `#if os(macOS)`.

It isn't in the Mac App Store, so channel logos are always on, and it updates itself from GitHub.
It's signed with your **Developer ID** and **notarized** by Apple, so it opens with a double-click
(no "unidentified developer" warning). Apple-silicon Macs (M1 and newer), macOS 15 or newer.

## Keys in the player

| Key | Live TV | Films and episodes |
| --- | --- | --- |
| Space | Pause / play | Pause / play |
| ↑ / ↓ | Previous / next channel | |
| ← / → | | Back / forward 10 s |
| F | Full screen | Full screen |
| Esc | Close | Close |

Moving the mouse brings the controls back. The Mac keyboard's media keys (▶︎❚❚) work too.

The Playback menu has all of these, plus Next Episode (⇧⌘N), Audio, Subtitles and Mini Player (⌥⌘M).

With a mouse or trackpad: a click shows or hides the controls, a double click is full screen, a pinch
fills or fits the picture. Two fingers up and down change the Mac's volume; two fingers sideways
seek in films and episodes (one jump when the fingers lift, so a swipe opens one provider connection).

The mini player keeps the same playback: don't call `removeFromSuperview` on the player's host view to
move it. That fires `onDisappear`, which stops the film; a direct `addSubview` doesn't (checked with a
small test app, 2026-11-06). Settings has "Full screen when playing", off by default.

## 1. One-time setup on your Mac

Everything from docs/IOS.md (Xcode 26.4+, XcodeGen, Java) applies. Then:

1. **Developer ID certificate**: Xcode → Settings → Accounts → your team → **Manage
   Certificates…** → **+** → **Developer ID Application**. (Only the account holder can make it:
   that's you.)
2. **Notarization login**, saved in your keychain so the script can use it:
   - Make an app-specific password at https://account.apple.com → Sign-In and Security →
     App-Specific Passwords (call it "Lumen notary").
   - In Terminal (your Apple Account email, your team id):

     ```sh
     xcrun notarytool store-credentials lumen-notary --apple-id "you@example.com" --team-id YOURTEAMID
     ```

     It asks for the app-specific password once.
3. **GitHub CLI**, to upload the DMG: `brew install gh`, then `gh auth login` (GitHub.com →
   HTTPS → log in with a web browser).

## 2. Try it

```sh
cd ios && ./generate.sh && open Lumen.xcodeproj
```

Pick the **LumenMac** scheme and **My Mac** at the top, then Run.

## 3. Ship a new version

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) under the **LumenMac** target in
   `ios/project.yml`.
2. `cd ios && NOTES="What's new" ./mac-release.sh`

The script archives, signs with Developer ID, makes `dist/Lumen.dmg` (drag Lumen to
Applications), sends it to Apple to notarize (a few minutes), staples the ticket, and uploads it
to the GitHub release tagged `mac` (title "Lumen for Mac 1.1"). It's never marked "latest",
because the TV app's update check reads the latest release. The link stays the same for every
version:

- https://github.com/lumen-tv/Lumen-TV/releases/download/mac/Lumen.dmg
- https://lumen-tv.github.io/mac (the website's button, forwards to the link above)

Copies of Lumen for Mac see the new version at their next launch (or Lumen → Check for Updates)
and offer to download it.
