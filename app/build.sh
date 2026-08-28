#!/usr/bin/env bash
# Build CacheBar.app into ~/Applications. Needs only the Xcode toolchain.
# ai-cache-bar.py is bundled into Contents/Resources, so a build deploys both
# halves and the app has no path into this repo at runtime.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SRC_DIR")"
APP="${1:-$HOME/Applications/CacheBar.app}"
BIN="$APP/Contents/MacOS/CacheBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO_DIR/ai-cache-bar.py" "$APP/Contents/Resources/ai-cache-bar.py"

# -parse-as-library: a lone .swift file is otherwise treated as top-level code,
# which conflicts with @main.
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit \
  "$SRC_DIR/CacheBar.swift" -o "$BIN"

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
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
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
