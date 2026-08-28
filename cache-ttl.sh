#!/usr/bin/env bash
# cache-ttl.sh — report prompt-cache warmth for a Claude Code session.
#
# Claude Code caches the conversation prefix with a 1-hour ephemeral TTL
# (verified: every local transcript reports ephemeral_1h_input_tokens, never 5m).
# Each cache read refreshes the TTL, so the deadline is:
#     last main-chain assistant message + 1h
# After that the next message re-writes the whole prefix at 1.25x base rate
# instead of reading it at 0.1x.
#
# Usage:
#   cache-ttl.sh                       # newest transcript, one status line
#   cache-ttl.sh --transcript PATH     # a specific session
#   cache-ttl.sh --session ID          # match a session id (prefix ok)
#   cache-ttl.sh --watch [--interval S]# live countdown in its own terminal
#   cache-ttl.sh --history             # cache invalidations in this session
#   cache-ttl.sh --json                # machine-readable
#   echo "$STATUSLINE_JSON" | cache-ttl.sh --stdin   # statusline widget
set -euo pipefail

TTL=${CLAUDE_CACHE_TTL_SECONDS:-3600}
WARN=${CLAUDE_CACHE_WARN_SECONDS:-300}
MODE=line
INTERVAL=15
TRANSCRIPT=""
SESSION=""
PROJECTS="$HOME/.claude/projects"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transcript) TRANSCRIPT="$2"; shift 2 ;;
    --session)    SESSION="$2"; shift 2 ;;
    --interval)   INTERVAL="$2"; shift 2 ;;
    --watch)      MODE=watch; shift ;;
    --history)    MODE=history; shift ;;
    --json)       MODE=json; shift ;;
    --stdin)      MODE=stdin; shift ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ $MODE == stdin ]]; then
  TRANSCRIPT=$(jq -r '.transcript_path // empty')
  MODE=line
fi

if [[ -z $TRANSCRIPT ]]; then
  if [[ -n $SESSION ]]; then
    TRANSCRIPT=$(ls -1t "$PROJECTS"/*/*"$SESSION"*.jsonl 2>/dev/null | head -1 || true)
  else
    TRANSCRIPT=$(ls -1t "$PROJECTS"/*/*.jsonl 2>/dev/null | head -1 || true)
  fi
fi

[[ -f ${TRANSCRIPT:-} ]] || { echo "no transcript found" >&2; exit 1; }

read -r -d '' PROG <<'JQ' || true
def ts: .timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def tot: (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0);
# One API request can produce several transcript entries (streaming partials,
# retries) sharing a requestId — keep the last of each so a single request is
# not counted as three cache rebuilds. Sidechains (subagents) have their own
# cache prefix and never refresh this session's, so they are excluded.
[ .[]
  | select(.message.usage != null and .requestId != null and ((.isSidechain // false) | not))
] | group_by(.requestId) | map(last) | sort_by(.timestamp) as $t
| ($t | length) as $n
| if $n == 0 then { state: "unknown", turns: 0 }
  else
    ($t | last) as $l
    | ($l.message.usage) as $u
    | ($l | ts) as $at
    | (now - $at) as $age
    | ($ttl - $age) as $left
    | {
        state:   (if $left > 0 then (if $left < $warn then "expiring" else "warm" end) else "cold" end),
        left:    ($left | floor),
        age:     ($age | floor),
        cached:  ($u | tot),
        turns:   $n,
        session: ($l.sessionId // "?"),
        model:   ($l.message.model // "?"),
        invalidations: [
          range(1; $n) as $i
          | ($t[$i-1].message.usage | tot) as $prev
          | ($t[$i].message.usage.cache_read_input_tokens // 0) as $got
          | select($prev > 5000 and $got < ($prev * 0.5)
                   and ($t[$i].message.usage.cache_creation_input_tokens // 0) > 0)
          | { at: ($t[$i] | ts), lost: ($prev - $got),
              rewrote: ($t[$i].message.usage.cache_creation_input_tokens // 0),
              gap: (($t[$i] | ts) - ($t[$i-1] | ts) | floor) }
        ]
      }
  end
JQ

snapshot() { jq -s --argjson ttl "$TTL" --argjson warn "$WARN" "$PROG" "$TRANSCRIPT"; }

hms() { # seconds -> 1h02m / 47m / 38s
  local s=$1
  (( s < 0 )) && s=$(( -s ))
  if   (( s >= 3600 )); then printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  elif (( s >= 60 ));   then printf '%dm' $(( s / 60 ))
  else printf '%ds' "$s"; fi
}

kt() { # tokens -> 122k
  local n=$1
  (( n >= 1000 )) && printf '%dk' $(( n / 1000 )) || printf '%d' "$n"
}

line() {
  local j; j=$(snapshot)
  local state left age cached
  state=$(jq -r .state <<<"$j")
  case $state in
    unknown) echo "cache: no turns yet"; return ;;
  esac
  left=$(jq -r .left <<<"$j"); age=$(jq -r .age <<<"$j"); cached=$(jq -r .cached <<<"$j")
  case $state in
    warm)     printf '🔥 cache %s left (%s)\n'      "$(hms "$left")" "$(kt "$cached")" ;;
    expiring) printf '⚠️  cache %s left (%s)\n'     "$(hms "$left")" "$(kt "$cached")" ;;
    cold)     printf '❄️  cache cold — idle %s, next turn rewrites %s\n' "$(hms "$age")" "$(kt "$cached")" ;;
  esac
}

case $MODE in
  json) snapshot ;;
  line) line ;;
  watch)
    trap 'echo; exit 0' INT
    while :; do printf '\r\033[K%s' "$(line)"; sleep "$INTERVAL"; done ;;
  history)
    j=$(snapshot)
    printf 'session %s — %s turns, %s cached now\n' \
      "$(jq -r .session <<<"$j")" "$(jq -r .turns <<<"$j")" "$(kt "$(jq -r .cached <<<"$j")")"
    n=$(jq '.invalidations | length' <<<"$j")
    if [[ $n == 0 ]]; then
      echo 'no cache invalidations — every turn read the full prefix'
    else
      printf '%s invalidation(s):\n' "$n"
      jq -r --argjson ttl "$TTL" '.invalidations[]
        | "  \(.at | strflocaltime("%m-%d %H:%M"))  rewrote \(.rewrote) tok after \(.gap)s idle" +
          (if .gap >= $ttl then "  (TTL expiry)" else "  (prefix changed)" end)' <<<"$j"
    fi
    line ;;
esac
