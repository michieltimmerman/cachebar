#!/usr/bin/env bash
# End-to-end tests: the real CacheBar binary (menu bar item and all) against fake
# HOMEs built by tests/make-fixtures.py, polling 30x faster (every 0.5 s). Every
# instance gets its own HOME, so your chats in ~/.claude and ~/.codex are never
# read; ai-cache-bar.py failures are simulated with CACHEBAR_SCRIPT stand-ins.
#
# The app runs from a copy of the bundle under the bundle id
# com.michieltimmerman.cachebar.e2e (same binary and script, re-signed ad hoc):
# CacheBar remembers the Python it found, and AppKit the menu bar item's position,
# in the defaults domain of the bundle id it runs as, and the tests must not touch
# your CacheBar settings. The test domain is deleted afterwards.
#
# Usage: tests/e2e.sh   (after packaging/build.sh; `mise run test` does both)
#   APP_BIN=.../CacheBar.app/Contents/MacOS/CacheBar   the build under test
#   PYTHON=...  the python3 the tests themselves use (default /usr/bin/python3)
#   KEEP=1      keep the temp dir (fixtures, app logs)
# Bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="${APP_BIN:-$HOME/Applications/CacheBar.app/Contents/MacOS/CacheBar}"
PY="${PYTHON:-/usr/bin/python3}"
TEST_ID=com.michieltimmerman.cachebar.e2e
SCALE=30
TMP="${TMPDIR:-/tmp}"
USER_NAME="${USER:-$(id -un)}"
PASS=0
FAIL=0
STARTED=$SECONDS

SRC_APP="$(cd "$(dirname "$APP_BIN")/../.." 2> /dev/null && pwd)"
if [ ! -x "$APP_BIN" ] || [ ! -f "$SRC_APP/Contents/Info.plist" ]; then
    echo "e2e: no CacheBar.app at $APP_BIN; run packaging/build.sh first (or set APP_BIN)" >&2
    exit 2
fi

ALL="$(cd "$(mktemp -d "$TMP/cachebar-e2e.XXXXXX")" && pwd -P)"
ok() { echo "  ok    $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
expect() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
not() { ! "$@"; }
# eventually <seconds> <desc> <cmd...>: poll until cmd succeeds. The cmd is re-run
# each poll, so it must be a function, not a "$(...)" baked in at call time.
eventually() {
    local secs=$1 desc=$2
    local end=$((SECONDS + secs))
    shift 2
    while ((SECONDS < end)); do
        if "$@"; then ok "$desc"; return 0; fi
        sleep 0.25
    done
    bad "$desc (not within ${secs}s)"
    return 1
}
scenario() { echo "• $1"; }

# halt <pid>: stopped first, so no new poll starts while its running script goes.
halt() {
    kill -STOP "$1" 2> /dev/null || return 0
    pkill -P "$1" 2> /dev/null
    kill "$1" 2> /dev/null
    kill -CONT "$1" 2> /dev/null
    wait "$1" 2> /dev/null
}
cleanup() {
    local f
    for f in "$ALL"/*/pid; do [ -f "$f" ] && halt "$(cat "$f")"; done
    defaults delete "$TEST_ID" > /dev/null 2>&1
    if [ "${KEEP:-}" = 1 ]; then echo "(kept $ALL)"; else rm -rf "$ALL"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ditto "$SRC_APP" "$ALL/CacheBar.app"
plutil -replace CFBundleIdentifier -string "$TEST_ID" "$ALL/CacheBar.app/Contents/Info.plist"
if ! codesign --force --sign - "$ALL/CacheBar.app" 2> /dev/null; then
    echo "e2e: could not re-sign the test copy of $SRC_APP" >&2
    exit 2
fi
BIN="$ALL/CacheBar.app/Contents/MacOS/CacheBar"
SCRIPT="$ALL/CacheBar.app/Contents/Resources/ai-cache-bar.py"
defaults delete "$TEST_ID" > /dev/null 2>&1

# fixture NAME [make-fixtures flags]: a fake HOME at $ALL/NAME/home whose chats
# were active just now (wall clock, or a later --now); sets NOW to its epoch.
fixture() {
    local name=$1
    shift
    mkdir -p "$ALL/$name"
    NOW=$("$PY" "$HERE/make-fixtures.py" "$ALL/$name/home" --now "$(date +%s)" "$@")
}

# run_app NAME [VAR=value ...] [-- CacheBar args]: the test copy with HOME=$ALL/NAME/home
# in a scrubbed environment. exec: `start` backgrounds this function, so without it
# $! would be a subshell and stopping it would leave the app running.
run_app() {
    local name=$1
    shift
    local envs=("HOME=$ALL/$name/home")
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    exec env -i USER="$USER_NAME" TMPDIR="$TMP" PATH=/usr/bin:/bin CACHEBAR_DEBUG=1 \
        CACHEBAR_NO_BANNERS=1 CACHEBAR_TIME_SCALE="$SCALE" "${envs[@]}" "$BIN" "$@"
}
start() { # start NAME [VAR=value ...] [-- CacheBar args]; logs to $ALL/NAME/app.log
    mkdir -p "$ALL/$1/home"
    run_app "$@" > "$ALL/$1/out.log" 2> "$ALL/$1/app.log" &
    echo $! > "$ALL/$1/pid"
}
# stop NAME...: pid -> pid.done, so cleanup never signals a PID that may since have
# been reused.
stop() {
    local n
    for n in "$@"; do
        halt "$(cat "$ALL/$n/pid")"
        mv "$ALL/$n/pid" "$ALL/$n/pid.done"
    done
}
gone() { [ -n "$1" ] && ! kill -0 "$1" 2> /dev/null; }
alive() { kill -0 "$(cat "$ALL/$1/pid")" 2> /dev/null; }

logged() { grep -q -- "$2" "$ALL/$1/app.log" 2> /dev/null; }   # regex
has() { grep -qF -- "$2" "$ALL/$1/app.log" 2> /dev/null; }     # literal
count() { local n; n=$(grep -c -- "$2" "$ALL/$1/app.log" 2> /dev/null); echo "${n:-0}"; }
count_is() { test "$(count "$1" "$2")" -eq "$3"; }
count_above() { test "$(count "$1" "$2")" -gt "$3"; }
notified() { logged "$1" "notify: $2"; }
first_poll_matches() { grep -m1 "poll: " "$ALL/$1/app.log" 2> /dev/null | grep -q -- "$2"; }
in_order() { # in_order NAME FIRST SECOND: FIRST is logged before SECOND
    local a b
    a=$(grep -n -- "$2" "$ALL/$1/app.log" | head -1 | cut -d: -f1)
    b=$(grep -n -- "$3" "$ALL/$1/app.log" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
all_polls_are() { # all_polls_are NAME LINE: at least one poll, and every one is LINE
    grep -q "poll: " "$ALL/$1/app.log" && ! grep "poll: " "$ALL/$1/app.log" | grep -qvxF "[cachebar] $2"
}
remembered_is() { test "$(defaults read "$TEST_ID" rememberedPython 2> /dev/null)" = "$1"; }

# expected_poll HOME [VAR=value ...]: the poll line ai-cache-bar.py --json implies,
# formatted as CacheBar logs it.
expected_poll() {
    local home=$1
    shift
    env -i HOME="$home" PATH=/usr/bin:/bin "$@" "$PY" "$SCRIPT" --json | "$PY" -c '
import json, sys
rows = json.load(sys.stdin)["sessions"]
counts = {}
for r in rows:
    counts[r["state"]] = counts.get(r["state"], 0) + 1
print(" ".join(["poll: %d sessions" % len(rows)] + sorted("%s=%d" % kv for kv in counts.items())))'
}
# chat_data HOME: the transcripts and ~/.codex files, by mtime and size.
chat_data() { (cd "$1" && find .claude/projects .codex -type f -exec stat -f '%N %m %z' {} + | sort); }

# fake NAME PYTHON-SOURCE: a stand-in for ai-cache-bar.py at $ALL/NAME/fake.py.
fake() { mkdir -p "$ALL/$1"; printf '%s\n' "$2" > "$ALL/$1/fake.py"; }
# payload NAME: replaces the JSON (stdin) that fake_payload NAME prints, atomically.
payload() { cat > "$ALL/$1/payload.tmp" && mv "$ALL/$1/payload.tmp" "$ALL/$1/payload.json"; }
fake_payload() {
    fake "$1" 'import os, sys
sys.stdout.write(open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "payload.json")).read())'
}

# add_rewrite NAME: "Tune flaky integration test", idle for 2h10m, takes a turn now
# that rewrites its whole cached prefix instead of reading it (the cold tax).
add_rewrite() {
    local f
    f=$(grep -l '"customTitle":"Tune flaky integration test"' "$ALL/$1"/home/.claude/projects/*/*.jsonl)
    "$PY" - "$f" << 'EOF'
import json, sys, time
path = sys.argv[1]
lines = open(path).read().splitlines()
turn = next(json.loads(l) for l in reversed(lines) if '"requestId"' in l and "<synthetic>" not in l)
turn["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z"
turn["uuid"] = "00000000-0000-4000-8000-999999999999"
turn["requestId"] = "req_e2e_rewrite"
turn["message"]["id"] = "msg_e2e_rewrite"
turn["message"]["usage"] = {
    "input_tokens": 4, "cache_creation_input_tokens": 220000, "cache_read_input_tokens": 3000,
    "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 220000},
    "output_tokens": 700, "service_tier": "standard"}
with open(path, "a") as fh:
    fh.write(json.dumps(turn, separators=(",", ":")) + "\n")
EOF
}

# Your own CacheBar, when running, legitimately rewrites the titles, plan and codex
# caches; the --notify state file is the SwiftBar plugin's, which CacheBar never runs.
USER_APP_RUNNING=$(pgrep -x CacheBar > /dev/null && echo 1 || true)
real_snapshot() {
    local f
    for f in state titles codex plan; do
        [ -n "$USER_APP_RUNNING" ] && [ "$f" != state ] && continue
        stat -f '%N %m %z' "$HOME/.claude/.ai-cache-bar-$f.json" 2> /dev/null
    done
    defaults read com.michieltimmerman.cachebar 2> /dev/null
}
REAL_BEFORE=$(real_snapshot)

scenario "healthy start: finds a Python, polls the fixture as ai-cache-bar.py --json sees it"
fixture healthy
H="$ALL/healthy/home"
CHATS_BEFORE=$(chat_data "$H")
start healthy AI_CACHE_NOW="$NOW" -- --notifications on
eventually 10 "detects a Python (no setting)" logged healthy "python: /"
DETECTED=$(sed -n 's/^\[cachebar\] python: //p' "$ALL/healthy/app.log" | head -1)
expect "  … one that exists ($DETECTED)" test -x "$DETECTED"
eventually 3 "  … and remembers it for the next launch" remembered_is "$DETECTED"
expect "runs the bundled ai-cache-bar.py" has healthy "script: $SCRIPT"
eventually 5 "polls" logged healthy "poll: "
n0=$(count healthy "poll: ")
sleep 3
n1=$(count healthy "poll: ")
expect "  … every 0.5 s (15 s / CACHEBAR_TIME_SCALE=$SCALE): $((n1 - n0)) polls in 3 s" \
    test $((n1 - n0)) -ge 3 -a $((n1 - n0)) -le 9
stop healthy
expect "no errors, the launch-time --calibrate included" not logged healthy "error:"
expect "a steady state notifies nothing (notifications on)" not logged healthy "notify:"
expect "the script ran against the fake HOME (its caches are there)" \
    test -f "$H/.claude/.ai-cache-bar-plan.json" -a -f "$H/.claude/.ai-cache-bar-titles.json"
expect "transcripts and ~/.codex are only read, never written" test "$CHATS_BEFORE" = "$(chat_data "$H")"
WANT=$(expected_poll "$H" AI_CACHE_NOW="$NOW")
expect "every poll matches ai-cache-bar.py --json on that HOME: \"$WANT\"" all_polls_are healthy "$WANT"
expect "  … the fixture's mix of states (warm, cold, compacted, codex estimates)" \
    grep -q " cold=.* compacted=1 .*est_warm=.* warm=" <<< "$WANT"

scenario "notifications: expiring, then cold, then a paid rewrite; none with --notifications off"
# One TTL for every chat: the newest ("Quick lint fixes", last turn 120 s before
# NOW) goes cold 12 s after NOW, with a 5 s warning; older chats are cold from the
# start, which the first poll only records.
fixture notify-on
fixture notify-off --now "$NOW"
start notify-on AI_CACHE_TTL_SECONDS=132 AI_CACHE_WARN_SECONDS=5 -- --notifications on
start notify-off AI_CACHE_TTL_SECONDS=132 AI_CACHE_WARN_SECONDS=5 -- --notifications off
eventually 6 "first poll" logged notify-on "poll: "
expect "  … the newest chat still warm then" first_poll_matches notify-on " warm=1$"
eventually 15 "\"Cache expiring\" for it" notified notify-on "Quick lint fixes — Cache expiring — [0-9]s left on 47k cached"
eventually 10 "then \"Cache went cold\"" notified notify-on "Quick lint fixes — Cache went cold — next turn rewrites 47k"
expect "  … in that order" in_order notify-on "Cache expiring" "Cache went cold"
off_saw_both() { logged notify-off "poll: .* expiring=1" && logged notify-off "poll: 10 sessions cold=6 "; }
eventually 3 "--notifications off sees the same transitions (expiring, then cold)" off_saw_both
add_rewrite notify-on
add_rewrite notify-off
eventually 5 "a turn that paid to rewrite a cold cache is announced" \
    notified notify-on "Tune flaky integration test — Rewrote 220k cached tokens after 2h10m idle — ≈"
sleep 1.5
expect "exactly those three, once each (chats cold at launch stay quiet)" count_is notify-on "notify:" 3
expect "--notifications off notifies none of them" not logged notify-off "notify:"
stop notify-on notify-off

scenario "an unusable Python setting is reported, never swapped for another"
mkdir -p "$ALL/py"
printf '#!/bin/sh\nprintf 2.7.18\nexit 3\n' > "$ALL/py/python2"
printf 'not a program\n' > "$ALL/py/python-noexec"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$PY" > "$ALL/py/python3"
chmod +x "$ALL/py/python2" "$ALL/py/python3"
start py-missing CACHEBAR_PYTHON=/nonexistent/python3
start py-false CACHEBAR_PYTHON=/usr/bin/false
start py-echo CACHEBAR_PYTHON=/bin/echo
start py-two CACHEBAR_PYTHON="$ALL/py/python2"
start py-noexec CACHEBAR_PYTHON="$ALL/py/python-noexec"
start py-arg CACHEBAR_PYTHON=/nonexistent/python3 -- --python "$ALL/py/python3"
eventually 8 "missing: \"does not exist\"" has py-missing \
    "error: python /nonexistent/python3 (set by CACHEBAR_PYTHON) is not usable: /nonexistent/python3 does not exist"
eventually 5 "/usr/bin/false: \"it exited 1\"" has py-false "is not usable: it exited 1"
eventually 5 "/bin/echo: \"doesn't look like Python\"" has py-echo "is not usable: it doesn't look like Python"
eventually 5 "a Python 2: \"older than 3.6\"" has py-two "is not usable: Python 2.7.18 is older than 3.6"
eventually 5 "a plain file: \"is not executable\"" has py-noexec "is not usable: $ALL/py/python-noexec is not executable"
eventually 8 "--python wins over CACHEBAR_PYTHON" has py-arg "python: $ALL/py/python3"
eventually 5 "  … and polls with it" logged py-arg "poll: "
sleep 2 # four more ticks, each looking again
quiet_failure() { alive "$1" && count_is "$1" "error: python" 1 && not logged "$1" "poll: " && not logged "$1" "python: "; }
for n in py-missing py-false py-echo py-two py-noexec; do
    expect "  $n: keeps running, says it once, never polls or picks another Python" quiet_failure "$n"
done
stop py-missing py-false py-echo py-two py-noexec py-arg

scenario "the Python vanishes while running (a brew or mise upgrade), then comes back"
mkdir -p "$ALL/vanish"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$PY" > "$ALL/vanish/python3"
chmod +x "$ALL/vanish/python3"
start vanish CACHEBAR_PYTHON="$ALL/vanish/python3"
eventually 8 "first poll" logged vanish "poll: "
mv "$ALL/vanish/python3" "$ALL/vanish/python3.away"
eventually 5 "the next poll says it can't start" has vanish "error: $ALL/vanish/python3 could not start"
eventually 3 "  … then that the setting is unusable" has vanish "is not usable: $ALL/vanish/python3 does not exist"
expect "  … still running" alive vanish
polls=$(count vanish "poll: ")
mv "$ALL/vanish/python3.away" "$ALL/vanish/python3"
eventually 5 "found again once it is back" count_is vanish "python: " 2
eventually 5 "  … and polling resumes" count_above vanish "poll: " "$polls"
stop vanish

scenario "ai-cache-bar.py failing (CACHEBAR_SCRIPT): each failure says what went wrong"
fake exit3 'import sys
sys.stderr.write("fixture: transcripts unreadable\nmore detail\n")
sys.exit(3)'
fake trace 'raise RuntimeError("fixture blew up")'
fake garbage 'print("<html>this is not JSON</html>")'
fake silent 'pass'
fake killed 'import os, signal
os.kill(os.getpid(), signal.SIGKILL)'
# Checked further down, once its 20 s timeout has passed.
fake hang 'import os, sys, time
with open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "starts"), "a") as fh:
    fh.write("%d %.3f %s\n" % (os.getpid(), time.time(), " ".join(sys.argv[1:])))
time.sleep(60)'
for n in exit3 trace garbage silent killed hang; do
    start "$n" CACHEBAR_PYTHON="$PY" CACHEBAR_SCRIPT="$ALL/$n/fake.py"
done
HANG_AT=$SECONDS
start nofile CACHEBAR_PYTHON="$PY" CACHEBAR_SCRIPT="$ALL/nofile/missing.py"
eventually 8 "non-zero exit: the status and the first stderr line" \
    has exit3 "error: ai-cache-bar.py exited 3: fixture: transcripts unreadable"
eventually 5 "a traceback: its exception, not \"Traceback (most recent call last)\"" \
    has trace "error: ai-cache-bar.py exited 1: RuntimeError: fixture blew up"
eventually 5 "output that isn't JSON: a decode error" has garbage "error: couldn't read ai-cache-bar.py --json: "
eventually 5 "no output at all" has silent "error: ai-cache-bar.py --json printed nothing"
eventually 5 "killed by a signal" has killed "error: ai-cache-bar.py was killed by signal 9"
eventually 5 "a CACHEBAR_SCRIPT that isn't there" has nofile "error: CACHEBAR_SCRIPT: $ALL/nofile/missing.py does not exist"
none_polled() { local n; for n in exit3 trace garbage silent killed nofile; do logged "$n" "poll: " && return 1; done; return 0; }
all_alive() { local n; for n in exit3 trace garbage silent killed nofile; do alive "$n" || return 1; done; }
expect "none of them got a poll through" none_polled
expect "all still running" all_alive
stop exit3 trace garbage silent killed nofile

scenario "a failing poll leaves the app running on its last data; the next good one recovers"
fixture flaky
fake flaky 'import os, sys
here = os.path.dirname(os.path.abspath(sys.argv[0]))
if open(os.path.join(here, "mode")).read().strip() == "good":
    os.execv(sys.executable, [sys.executable, os.environ["E2E_REAL_SCRIPT"]] + sys.argv[1:])
sys.stderr.write("fixture: switched to failing\n")
sys.exit(4)'
echo good > "$ALL/flaky/mode"
start flaky CACHEBAR_PYTHON="$PY" CACHEBAR_SCRIPT="$ALL/flaky/fake.py" E2E_REAL_SCRIPT="$SCRIPT"
eventually 8 "good polls" logged flaky "poll: 10 sessions "
echo fail > "$ALL/flaky/mode"
eventually 3 "the failure is logged" has flaky "error: ai-cache-bar.py exited 4: fixture: switched to failing"
eventually 3 "  … again on the next polls (it keeps polling)" count_above flaky "error: " 2
expect "  … still running" alive flaky
polls=$(count flaky "poll: ")
echo good > "$ALL/flaky/mode"
eventually 3 "the next good poll is applied" count_above flaky "poll: 10 sessions " "$polls"
stop flaky

scenario "robust decoding: fractional plan %, odd optional fields, a bare array; real errors named by path"
fake_payload decode
payload decode << 'EOF'
{"sessions": [
  {"tool": "claude", "session": "e2e-1", "title": "Fractional budget", "label": "demo@main",
   "display": "Fractional budget", "model": "claude-opus-5", "age": 30, "left": 3570,
   "cached": 50000, "ttl_known": true, "state": "warm", "from_a_newer_script": {"x": [1, 2]}},
  {"tool": "claude", "session": "e2e-2", "label": "api@main", "display": "api@main",
   "model": "claude-opus-5", "age": 4000, "left": -400, "cached": 210000,
   "ttl_known": true, "ttl_estimate": false, "state": "cold"}],
 "budget": {"chats": 2, "cold_chats": 1, "compaction_pct_5h": 2.5, "cold_share_pct_5h": 2.1,
            "used_pct_5h": 41.6, "left_pct_5h": 58.4, "would_exhaust_5h": false}}
EOF
fake_payload bare
payload bare << 'EOF'
[{"tool": "claude", "session": "e2e-3", "label": "old@main", "display": "old@main",
  "model": "claude-opus-5", "age": 60, "left": 3540, "cached": 9000, "ttl_known": true, "state": "warm"}]
EOF
fake_payload nochats
payload nochats << 'EOF'
{"sessions": [], "budget": {"cold_chats": 0, "compaction_pct_5h": 0, "cold_share_pct_5h": 0, "would_exhaust_5h": false}}
EOF
fake_payload badage
payload badage << 'EOF'
{"sessions": [
  {"tool": "claude", "session": "e2e-4", "label": "a@main", "display": "a@main", "model": "m",
   "age": 30, "left": 3570, "cached": 1, "ttl_known": true, "state": "warm"},
  {"tool": "claude", "session": "e2e-5", "label": "b@main", "display": "b@main", "model": "m",
   "age": "30", "left": 3570, "cached": 1, "ttl_known": true, "state": "warm"}], "budget": null}
EOF
for n in decode bare nochats badage; do
    start "$n" CACHEBAR_PYTHON="$PY" CACHEBAR_SCRIPT="$ALL/$n/fake.py" -- --notifications on
done
eventually 8 "fractional used/left %, missing reset, calibration and sample age: polls" \
    logged decode "poll: 2 sessions cold=1 warm=1"
# Fractional left (3.6 -> "4"), and optional fields of the wrong type, which blank
# themselves instead of failing the payload.
payload decode << 'EOF'
{"sessions": [
  {"tool": "claude", "session": "e2e-1", "title": "Fractional budget", "label": "demo@main",
   "display": "Fractional budget", "model": "claude-opus-5", "age": 31, "left": 3569,
   "cached": 50000, "ttl_known": true, "state": "warm"},
  {"tool": "claude", "session": "e2e-2", "label": "api@main", "display": "api@main",
   "model": "claude-opus-5", "age": 4001, "left": -401, "cached": 210000,
   "ttl_known": true, "ttl_estimate": false, "state": "cold"}],
 "budget": {"chats": 2, "cold_chats": 1, "compaction_pct_5h": 12.5, "cold_share_pct_5h": 10.4,
            "used_pct_5h": 96.4, "left_pct_5h": 3.6, "would_exhaust_5h": true,
            "reset": 5, "calibration": "fitted", "usage_sample_age": "old"}}
EOF
eventually 5 "wrong-typed optional fields still poll, and a tight budget notifies with left % rounded" \
    has decode "notify: Compacting everything would exhaust your 5h limit — 2 chats ≈ 12.5% but only 4% left. Cold: api@main"
sleep 1
expect "  … once" count_is decode "notify:" 1
expect "  … no decode errors" not logged decode "error:"
eventually 5 "an older script's bare array: polls" logged bare "poll: 1 sessions warm=1"
eventually 5 "a missing required field: named" has nochats "error: couldn't read ai-cache-bar.py --json: budget.chats: missing"
eventually 5 "a wrong type: named with its index" has badage "error: couldn't read ai-cache-bar.py --json: sessions[1].age: expected Int"
stop decode bare nochats badage

scenario "command line"
mkdir -p "$ALL/cli"
CLI_NOW=$("$PY" "$HERE/make-fixtures.py" "$ALL/cli/home")
want=$(plutil -extract CFBundleShortVersionString raw "$SRC_APP/Contents/Info.plist")
out=$(env -i HOME="$ALL/cli/home" PATH=/usr/bin:/bin "$APP_BIN" --version 2>&1)
expect "--version prints the bundle version ($want)" test "$out" = "$want"
out=$(run_app cli -- --help 2>&1)
rc=$?
expect "--help exits 0" test "$rc" -eq 0
expect "  … listing every setting" grep -q -- "--lookback-hours N" <<< "$out"
(run_app cli -- --no-such-flag) > /dev/null 2> "$ALL/cli/err"
rc=$?
expect "an unknown option: exit 2" test "$rc" -eq 2
expect "  … naming it, with the usage" bash -c "grep -q 'unknown option --no-such-flag' '$ALL/cli/err' && grep -q 'Usage: CacheBar' '$ALL/cli/err'"
(run_app cli -- --warn-minutes 0) > /dev/null 2>&1
expect "--warn-minutes 0: exit 2" test $? -eq 2
(run_app cli -- --notifications maybe) > /dev/null 2>&1
expect "--notifications maybe: exit 2" test $? -eq 2
(run_app cli -- --python /nonexistent/python3) > /dev/null 2>&1
expect "--python with a path that isn't there: exit 2" test $? -eq 2
# --text under the script's pinned clock, as --status should show it.
script_text() { env -i HOME="$ALL/cli/home" PATH=/usr/bin:/bin AI_CACHE_NOW="$CLI_NOW" AI_CACHE_INLINE_FIT=0 "$@" "$PY" "$SCRIPT" --text; }
body() { sed 1,4d <<< "$1"; }
out=$(run_app cli AI_CACHE_NOW="$CLI_NOW" -- --status 2> "$ALL/cli/err")
rc=$?
expect "--status: exit 0" test "$rc" -eq 0
expect "  … names the Python (the remembered one)" grep -q "^python:   /.* (Python 3\.[0-9]*\.[0-9]*, detected)$" <<< "$out"
expect "  … and the bundled script" grep -qxF "script:   $SCRIPT" <<< "$out"
expect "  … then prints ai-cache-bar.py --text" test "$(body "$out")" = "$(script_text)"
defaults write "$TEST_ID" warnMinutes -int 4
out=$(run_app cli AI_CACHE_NOW="$CLI_NOW" -- --status 2> /dev/null)
expect "a saved setting (warnMinutes 4, test domain) reaches the script" \
    test "$(body "$out")" = "$(script_text AI_CACHE_WARN_SECONDS=240)"
expect "  … and is shown" grep -q "^settings: .* · warn 4 minutes · " <<< "$out"
out=$(run_app cli AI_CACHE_NOW="$CLI_NOW" AI_CACHE_WARN_SECONDS=600 -- --status 2> /dev/null)
expect "the environment wins over it" test "$(body "$out")" = "$(script_text AI_CACHE_WARN_SECONDS=600)"
expect "  … and says so" grep -q " · warn 10m (AI_CACHE_WARN_SECONDS) · " <<< "$out"
out=$(run_app cli AI_CACHE_NOW="$CLI_NOW" AI_CACHE_WARN_SECONDS=600 -- --status --warn-minutes 2 --max-rows 3 2> /dev/null)
expect "arguments win over both" \
    test "$(body "$out")" = "$(script_text AI_CACHE_WARN_SECONDS=120 AI_CACHE_MAX_ROWS=3)"
expect "  … and say so" grep -q " · warn 2 minutes (--warn-minutes) · 3 rows (--max-rows) · " <<< "$out"
defaults delete "$TEST_ID" warnMinutes > /dev/null 2>&1
out=$(run_app cli CACHEBAR_PYTHON=/nonexistent/python3 -- --status 2>&1)
rc=$?
expect "--status with an unusable CACHEBAR_PYTHON: exit 1" test "$rc" -eq 1
expect "  … saying which and why" grep -qF \
    "CacheBar: the python3 set by CACHEBAR_PYTHON (/nonexistent/python3) isn't usable: /nonexistent/python3 does not exist" <<< "$out"
out=$(run_app cli CACHEBAR_PYTHON="$PY" CACHEBAR_SCRIPT="$ALL/exit3/fake.py" -- --status 2>&1)
rc=$?
expect "--status with a failing script: exit 1" test "$rc" -eq 1
expect "  … with its error" grep -qF "CacheBar: ai-cache-bar.py --text exited 3: fixture: transcripts unreadable" <<< "$out"

scenario "a hung script is killed after 20 s, and polls never overlap (started with the failures above)"
# The killer is a GCD asyncAfter, whose default leeway lets it fire up to ~2 s late.
left=$((HANG_AT + 30 - SECONDS))
[ "$left" -lt 5 ] && left=5
eventually "$left" "\"timed out after 20s\"" has hang "error: ai-cache-bar.py timed out after 20s"
# The launch-time --calibrate run hangs too (120 s timeout); only polls count here.
polls_started_at_least() { test "$(grep -c -- " --json$" "$ALL/hang/starts")" -ge "$1"; }
hung=$(grep -m1 -- " --json$" "$ALL/hang/starts" | cut -d' ' -f1)
expect "  … the hung poll is gone" gone "$hung"
eventually 3 "  … and the next poll starts" polls_started_at_least 2
expect "  … only then: none overlapped it" \
    awk '/ --json$/ { n++; if (n == 1) t = $2; if (n == 2) exit ($2 - t < 19.5) }' "$ALL/hang/starts"
stop hang

echo "• isolation (all scenarios)"
no_survivors() {
    local f
    for f in "$ALL"/*/pid*; do gone "$(cat "$f")" || return 1; done
    ! pgrep -f "$ALL" > /dev/null
}
expect "every CacheBar and script started here has quit" no_survivors
expect "your ~/.claude caches${USER_APP_RUNNING:+ (just the --notify state: your own CacheBar is running)} and CacheBar settings untouched" \
    test "$REAL_BEFORE" = "$(real_snapshot)"

echo
echo "$PASS passed, $FAIL failed ($((SECONDS - STARTED))s)"
[ "$FAIL" -eq 0 ]
