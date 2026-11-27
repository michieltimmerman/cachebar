#!/bin/bash
# Golden tests for ai-cache-bar.py: build a fake HOME (tests/make-fixtures.py),
# run the script against it with the clock pinned, and diff --json, --text and
# --swiftbar against tests/golden/. Nothing is read from the real HOME.
#
#   tests/script-tests.sh            run (PYTHON=... to pick another interpreter)
#   tests/script-tests.sh --update   rewrite the goldens after an intended change
#
# Cases: "fitted" (enough plan history for the self-calibration), "default"
# (too little history) and "env" (AI_CACHE_5H_PER_PCT set). Bash 3.2-safe.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(dirname "$here")/ai-cache-bar.py"
golden="$here/golden"
python="${PYTHON:-/usr/bin/python3}"
update=0
case "${1:-}" in
  --update) update=1 ;;
  "") ;;
  *) echo "usage: $0 [--update]" >&2; exit 2 ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cachebar-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$golden"

pass=0
fail=0
failed=""

# The script under a scrubbed environment: only HOME, the pinned clock and the
# case's own knobs, so a developer's AI_CACHE_* settings can't leak in.
run_script() {  # home now mode [VAR=value ...]
  local home=$1 now=$2 mode=$3
  shift 3
  env -i HOME="$home" PATH=/usr/bin:/bin PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1 \
    AI_CACHE_NOW="$now" "$@" "$python" "$script" "--$mode" \
    | "$python" -c 'import sys; sys.stdout.write(sys.stdin.read().replace(sys.argv[1], "$HOME"))' "$home"
}

check() {  # label golden-file actual-file
  local label=$1 want=$2 got=$3
  if [ "$update" = 1 ]; then
    cp "$got" "$want"
    pass=$((pass + 1))
  elif [ -f "$want" ] && diff -q "$want" "$got" >/dev/null; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed="$failed $label"
    echo "FAIL $label"
    if [ -f "$want" ]; then
      diff -u "$want" "$got" | head -40 || true
    else
      echo "  (no golden: $want — run with --update)"
    fi
  fi
}

# Contract checks that hold whatever the goldens say, so --update can't bless a
# broken calibration path.
contract() {  # label json-file expected-source
  local label=$1
  if "$python" - "$2" "$3" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))["budget"]
c = b["calibration"]
assert sorted(c) == ["per_pct_5h", "source", "windows"], c
assert c["source"] == sys.argv[2], "source %r, expected %r" % (c["source"], sys.argv[2])
assert type(c["windows"]) is int and isinstance(c["per_pct_5h"], (int, float)), c
for k in ("used_pct_5h", "left_pct_5h", "usage_sample_age"):
    assert b[k] is None or type(b[k]) is int, "%s = %r" % (k, b[k])
if c["source"] == "fitted":  # the fixture's plan charges 1% per 120000
    assert abs(c["per_pct_5h"] - 120000) <= 6000, c
EOF
  then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed="$failed $label"
    echo "FAIL $label"
  fi
}

run_case() {  # name expected-source fixture-flags [VAR=value ...]
  local name=$1 source=$2 flags=$3
  shift 3
  local home="$tmp/home-$name" now mode
  # shellcheck disable=SC2086  # flags are deliberately word-split
  now="$("$python" "$here/make-fixtures.py" "$home" $flags)"
  for mode in json text swiftbar; do
    run_script "$home" "$now" "$mode" "$@" > "$tmp/$name.$mode"
    check "$name --$mode" "$golden/$name.$mode" "$tmp/$name.$mode"
  done
  contract "$name contract" "$tmp/$name.json" "$source"
  # The first --json computed the plan fit; this one reads it back from the cache.
  run_script "$home" "$now" json "$@" > "$tmp/$name.json.cached"
  check "$name --json (cached fit)" "$tmp/$name.json" "$tmp/$name.json.cached"
}

run_case fitted fitted ""
run_case default default "--thin-history"
run_case env env "" AI_CACHE_5H_PER_PCT=150000

# --compat: the fixture has everything the script reads (exit 0), and each kind
# of breakage is named — a lost field fails, a lost title only warns.
compat_case() {  # label golden-name expected-exit sed-expression
  local label=$1 name=$2 want_rc=$3 expr=$4 home="$tmp/home-compat-$2" now rc f
  now="$("$python" "$here/make-fixtures.py" "$home")"
  if [ -n "$expr" ]; then
    find "$home/.claude/projects" -name '*.jsonl' | while read -r f; do
      sed -i '' -e "$expr" "$f"
    done
  fi
  set +e
  run_script "$home" "$now" compat > "$tmp/$name.compat"
  rc=$?  # pipefail: the script's own exit
  set -e
  check "$label" "$golden/$name.compat" "$tmp/$name.compat"
  if [ "$rc" = "$want_rc" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); failed="$failed $label-exit"; echo "FAIL $label: exit $rc, expected $want_rc"
  fi
}
compat_case "--compat" compat 0 ""
compat_case "--compat (cache fields renamed)" compat-broken 1 's/cache_read_input_tokens/cache_reads/g'
compat_case "--compat (no titles)" compat-untitled 0 's/"ai-title"/"ai-label"/g; s/"custom-title"/"custom-label"/g'

if [ "$update" = 1 ]; then
  echo "script-tests: goldens rewritten in $golden ($fail contract failure(s))"
else
  echo "script-tests: $pass passed, $fail failed${failed:+ —$failed}"
fi
[ "$fail" = 0 ]
