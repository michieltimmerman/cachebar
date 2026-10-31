#!/usr/bin/env bash
# Assemble CacheBar.app from a SwiftPM release build. Needs only the Xcode
# toolchain. ai-cache-bar.py is bundled into Contents/Resources, so a build
# deploys both halves and the app has no path into this repo at runtime.
#
# Usage: build.sh [target.app]   (default ~/Applications/CacheBar.app)
#   VERSION               CFBundleShortVersionString (default: latest git tag, else 0.0.0-dev)
#   UNIVERSAL=1           build for arm64 and x86_64 (release builds)
#   CACHEBAR_BUNDLE_ID    bundle identifier (default com.michieltimmerman.cachebar)
#   CODESIGN_IDENTITY     signing identity, "-" for ad-hoc. Unset: the first Developer
#                         ID / Apple Development identity in the keychain, else ad-hoc.
#                         A Developer ID gets the hardened runtime and a timestamp, as
#                         notarization requires.
#   SHARED=1              the build leaves this Mac (dist, releases): only a Developer
#                         ID or ad-hoc, never an Apple Development identity, whose
#                         signature carries the developer's personal Apple ID.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/CacheBar.app}"
BUNDLE_ID="${CACHEBAR_BUNDLE_ID:-com.michieltimmerman.cachebar}"
TAG="$(git -C "$PKG_DIR" describe --tags --abbrev=0 2> /dev/null || true)"
VERSION="${VERSION:-${TAG#v}}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD="$(git -C "$PKG_DIR" rev-list --count HEAD 2> /dev/null || echo 1)"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-}" = 1 ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release "${ARCH_FLAGS[@]}" --package-path "$PKG_DIR"
BIN_PATH="$(swift build -c release "${ARCH_FLAGS[@]}" --package-path "$PKG_DIR" --show-bin-path)/CacheBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/CacheBar"
cp "$PKG_DIR/ai-cache-bar.py" "$APP/Contents/Resources/ai-cache-bar.py"
cp "$PKG_DIR/packaging/CacheBar.icns" "$APP/Contents/Resources/CacheBar.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CacheBar</string>
  <!-- Notification authorization is cached per bundle id and cannot be reset from
       the CLI, so a denial recorded against an old id needs a new one. -->
  <key>CFBundleIdentifier</key><string>BUNDLE_ID</string>
  <key>CFBundleName</key><string>CacheBar</string>
  <key>CFBundleDisplayName</key><string>CacheBar</string>
  <key>CFBundleIconFile</key><string>CacheBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>VERSION</string>
  <key>CFBundleVersion</key><string>BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Michiel Timmerman. MIT License.</string>
</dict>
</plist>
PLIST
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"

# Notifications work with any signature: macOS grants UNUserNotificationCenter to
# ad-hoc and Apple Development builds alike when they run from a normal folder such
# as ~/Applications, and refuses it under /private/tmp ("UNErrorDomain Code=1:
# Notifications are not allowed for this application"), where the app falls back
# to the deprecated NSUserNotificationCenter (no terminal-notifier needed).
IDENTITY="${CODESIGN_IDENTITY:-}"
WANTED='Developer ID Application|Apple Development'
[ "${SHARED:-}" = 1 ] && WANTED='Developer ID Application'
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v re="$WANTED" '$0 ~ re {print $2; exit}')
fi
if [ "${SHARED:-}" = 1 ] && [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] \
    && [[ "$IDENTITY" != "Developer ID Application"* ]]; then
  echo "a shared build is signed with a Developer ID Application identity or ad-hoc, not '$IDENTITY'" >&2
  exit 1
fi

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
  echo "ad-hoc signed"
elif [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  # A release build: failing to sign must fail the build, not ship unsigned.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "signed: $IDENTITY (hardened runtime)"
elif codesign --force --sign "$IDENTITY" "$APP" > /dev/null 2>&1; then
  echo "signed: $IDENTITY"
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "signing with $IDENTITY failed" >&2
  exit 1
else
  codesign --force --sign - "$APP"
  echo "signing with $IDENTITY failed, fell back to ad-hoc"
fi
codesign --verify --strict "$APP"

echo "built $APP ($VERSION, build $BUILD$( [ "${UNIVERSAL:-}" = 1 ] && echo ", universal"))"
