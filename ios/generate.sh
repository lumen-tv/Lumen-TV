#!/bin/sh
# Builds Lumen.xcodeproj from project.yml. Run it after every pull, then open the project.
# Needs XcodeGen: brew install xcodegen
set -e
cd "$(dirname "$0")"

# Remember your Apple team, so you don't have to pick it in Xcode after every generate.
# Your free "Personal Team" id is in the certificate Xcode made the first time you signed.
if [ ! -f Config/Local.xcconfig ]; then
  team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')
  if [ -n "$team" ]; then
    echo "DEVELOPMENT_TEAM = $team" > Config/Local.xcconfig
    echo "Saved your Apple team ($team) in Config/Local.xcconfig."
  else
    echo "No Apple Development certificate yet: pick your team once in Xcode (see docs/IOS.md)."
  fi
fi

# iCloud sync needs the paid team: add "LUMEN_ICLOUD = YES" to Config/Local.xcconfig once it's active.
if grep -q "^LUMEN_ICLOUD *= *YES" Config/Local.xcconfig 2>/dev/null; then
  echo "iCloud sync on."
  xcodegen generate --spec project-icloud.yml
else
  echo "iCloud sync off (add LUMEN_ICLOUD = YES to Config/Local.xcconfig once your paid team is active)."
  xcodegen generate
fi
