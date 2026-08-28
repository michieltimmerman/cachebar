#!/usr/bin/env bash
# Regenerate packaging/CacheBar.icns from render-icon.swift. Only needed when
# the icon design changes — the .icns is committed.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift "$DIR/render-icon.swift" "$TMP/icon_1024.png" 1024

ICONSET="$TMP/CacheBar.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$DIR/CacheBar.icns"
echo "wrote $DIR/CacheBar.icns"
