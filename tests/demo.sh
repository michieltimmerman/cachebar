#!/usr/bin/env bash
# Start CacheBar with demo data, for screenshots: a fake HOME (tests/make-fixtures.py)
# whose made-up chats were active just now — warm, expiring, cold, compacted and
# codex rows — on the live clock, so they age as you watch. Your real chats are
# never read, and banners are off.
# If your own CacheBar is running, a second icon appears next to it; quit yours
# first for a clean menu bar. This is the installed app, so it uses CacheBar's own
# settings, and changes made in its Settings window are saved there.
# Ctrl-C ends the demo.
#
# Usage: tests/demo.sh [extra CacheBar arguments]
#   APP_BIN=.../CacheBar.app/Contents/MacOS/CacheBar   another build
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="${APP_BIN:-$HOME/Applications/CacheBar.app/Contents/MacOS/CacheBar}"
PY="${PYTHON:-/usr/bin/python3}"
[ -x "$APP_BIN" ] || { echo "demo: no CacheBar at $APP_BIN; run packaging/build.sh first" >&2; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/cachebar-demo.XXXXXX")
PID=""
cleanup() {
    if [ -n "$PID" ]; then kill "$PID" 2> /dev/null || true; wait "$PID" 2> /dev/null || true; fi
    rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

"$PY" "$HERE/make-fixtures.py" "$T/home" --now "$(date +%s)" --no-quota > /dev/null

echo "CacheBar demo running on made-up chats: click its menu bar item; Ctrl-C to stop."
# Backgrounded and waited for, so the trap stops the app however this script ends.
env -i HOME="$T/home" USER="${USER:-$(id -un)}" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin \
    CACHEBAR_NO_BANNERS=1 ${CACHEBAR_PYTHON:+"CACHEBAR_PYTHON=$CACHEBAR_PYTHON"} \
    "$APP_BIN" "$@" &
PID=$!
wait "$PID" || true
PID=""
