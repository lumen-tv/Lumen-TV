#!/bin/sh
# Run by Xcode before compiling (a "Run Script" build phase from project.yml): builds the
# shared Kotlin code (../shared) into Shared.framework with Gradle, for the device or
# Simulator Xcode is building for. The first build downloads Kotlin's iOS compiler (a few
# minutes); later builds only redo what changed.
set -e

# Xcode doesn't read your shell profile, so find Java and the Android SDK the way they're
# installed with Homebrew (docs/IOS.md). The Android SDK is needed because Gradle sets up
# the Android side of the shared module too.
BREW=/opt/homebrew
[ -d "$BREW" ] || BREW=/usr/local
if [ -z "$JAVA_HOME" ]; then
  for jdk in "$BREW/opt/openjdk@17" "$BREW/opt/openjdk@21" "$BREW/opt/openjdk"; do
    if [ -d "$jdk/libexec/openjdk.jdk/Contents/Home" ]; then
      export JAVA_HOME="$jdk/libexec/openjdk.jdk/Contents/Home"
      break
    fi
  done
fi
[ -n "$JAVA_HOME" ] || export JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null || true)"
if [ -z "$ANDROID_HOME" ] && [ -d "$BREW/share/android-commandlinetools" ]; then
  export ANDROID_HOME="$BREW/share/android-commandlinetools"
fi

if [ -z "$JAVA_HOME" ]; then
  echo "error: Java not found. Install it with: brew install openjdk@17"
  exit 1
fi

cd "$SRCROOT/.."
./gradlew :shared:embedAndSignAppleFrameworkForXcode
