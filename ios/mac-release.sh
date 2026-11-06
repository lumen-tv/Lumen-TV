#!/bin/sh
# Builds the Mac app's DMG for the website, signed with your Developer ID and notarized by
# Apple (so it opens without "can't be checked" warnings), then uploads it to the GitHub
# release tagged "mac" if the GitHub CLI is set up. One-time setup is in docs/MAC.md.
#
#   ./mac-release.sh            build dist/Lumen.dmg and upload it
#   ./mac-release.sh --no-upload
set -e
cd "$(dirname "$0")"

team=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig 2>/dev/null)
if [ -z "$team" ]; then
  echo "error: no DEVELOPMENT_TEAM in Config/Local.xcconfig (run ./generate.sh once, see docs/IOS.md)"
  exit 1
fi

./generate.sh
rm -rf dist
mkdir -p dist

echo "== Building (Release, Apple silicon)"
xcodebuild -project Lumen.xcodeproj -scheme LumenMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath dist/Lumen.xcarchive \
  -allowProvisioningUpdates archive | tail -n 5

cat > dist/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
</dict>
</plist>
PLIST

echo "== Signing with Developer ID"
xcodebuild -exportArchive -archivePath dist/Lumen.xcarchive -exportPath dist/app \
  -exportOptionsPlist dist/export.plist -allowProvisioningUpdates | tail -n 3

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/app/Lumen.app/Contents/Info.plist)

echo "== Making the DMG (Lumen $version)"
mkdir -p dist/dmg
cp -R dist/app/Lumen.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "Lumen" -srcfolder dist/dmg -ov -format UDZO dist/Lumen.dmg >/dev/null
codesign --sign "Developer ID Application" --timestamp dist/Lumen.dmg

echo "== Notarizing (Apple checks it, usually 2-10 minutes)"
xcrun notarytool submit dist/Lumen.dmg --keychain-profile lumen-notary --wait
xcrun stapler staple dist/Lumen.dmg
spctl --assess --type open --context context:primary-signature -v dist/Lumen.dmg || true

echo "Built dist/Lumen.dmg (Lumen $version)."

[ "$1" = "--no-upload" ] && exit 0
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI not installed: upload dist/Lumen.dmg to the 'mac' release by hand (docs/MAC.md)."
  exit 0
fi
repo=lumen-tv/Lumen-TV
notes=${NOTES:-"Lumen for Mac $version."}
if gh release view mac --repo "$repo" >/dev/null 2>&1; then
  gh release upload mac dist/Lumen.dmg --repo "$repo" --clobber
  gh release edit mac --repo "$repo" --title "Lumen for Mac $version" --notes "$notes" --latest=false
else
  # --latest=false: the TV app's update check reads the repo's "latest" release, which must
  # stay the TV app's.
  gh release create mac dist/Lumen.dmg --repo "$repo" --title "Lumen for Mac $version" \
    --notes "$notes" --latest=false
fi
echo "Uploaded: https://github.com/$repo/releases/download/mac/Lumen.dmg"
