#!/usr/bin/env bash
# Assemble CacheBar.app from a SwiftPM release build. Needs only the Xcode
# toolchain. ai-cache-bar.py is bundled into Contents/Resources, so a build
# deploys both halves and the app has no path into this repo at runtime.
#
# Usage: build.sh [target.app]   (default ~/Applications/CacheBar.app)
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/CacheBar.app}"

swift build -c release --package-path "$PKG_DIR"
BIN_PATH="$(swift build -c release --package-path "$PKG_DIR" --show-bin-path)/CacheBar"

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
  <key>CFBundleIdentifier</key><string>com.michieltimmerman.cachebar</string>
  <key>CFBundleName</key><string>CacheBar</string>
  <key>CFBundleIconFile</key><string>CacheBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# macOS refuses UNUserNotificationCenter for ad-hoc signed apps
# ("UNErrorDomain Code=1: Notifications are not allowed for this application"),
# so sign with a real identity when the keychain has one. An Apple Development
# cert from a free personal team is enough; ad-hoc still runs, it just falls back
# to terminal-notifier for alerts.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    && echo "signed: $IDENTITY" \
    || { codesign --force --sign - "$APP" >/dev/null 2>&1; echo "signing failed, fell back to ad-hoc"; }
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "ad-hoc signed — native notifications unavailable, will use terminal-notifier"
fi

echo "built $APP"
