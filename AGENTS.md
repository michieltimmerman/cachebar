# AGENTS.md — working on CacheBar

Operating guide for AI agents (and humans) changing this repo. It encodes the
architecture rules and the platform facts this tool is built on, with the
evidence for each. Almost everything here was established **empirically**
(2026-08-28 → 2026-08-31) by reading the files the Claude desktop app, Claude
Code, and Codex write locally — none of it is contractual API behavior unless
marked so. Expect drift as those apps evolve; re-verify a fact before building
on it.

## Architecture rules

1. **`ai-cache-bar.py` is the single source of truth.** All state derivation —
   warmth, titles, budget, calibrations — happens in the Python.
   `Sources/CacheBar/CacheBar.swift` is a thin viewer that renders `--json`
   output. Never derive state in Swift; the rules must not fork between the
   app, `--text`, `--swiftbar`, and `--notify`.
2. **Stdlib-only `/usr/bin/python3`.** The script runs under SwiftBar's and
   launchd's minimal `PATH`. No jq, no mise, no third-party imports at runtime.
3. **A build is a deploy of both halves.** `packaging/build.sh` bundles
   `ai-cache-bar.py` into `CacheBar.app/Contents/Resources`, and the app polls
   that bundled copy (resolution: `CACHEBAR_SCRIPT` env > bundled > legacy
   `~/.claude/scripts` fallback). **After editing the Python, rebuild and
   relaunch the app** or it keeps running the old copy.
4. **Nothing is clickable.** Rows and notifications are information, not
   actions — there is no safe way to open a chat (see Hazards). Do not add
   links, `-execute` handlers, or buttons that "open" a session.
5. **Known ≠ estimated, and the UI must say which.** Claude's TTL is
   contractual → deterministic 🔥/⚠️/❄️ states, exact countdowns,
   notifications. Codex's TTL is a measured estimate → traffic light 🟢/🟡/🔴,
   `~` prefixes, the measured odds shown in the uncertain zone, and **never**
   notifications (`ttl_estimate` gates them out in both halves).
6. **Notification shape:** the chat title is the headline (macOS banners give
   one bold line, ~35 chars — a `"Cache expiring:"` prefix pushes real titles
   out); the state goes in the body. One `-group` per session so a session
   replaces its own earlier banner, never another's. Fire on **transitions
   only** (CLI: `~/.claude/.ai-cache-bar-state.json`; app: in-memory maps),
   seeded on first poll so launch never floods.
7. **JSON contract:** `--json` emits `{"sessions": [...], "budget": {...}}`;
   the Swift decoder falls back to a bare array for older scripts. Don't break
   either shape.
8. **mise is the task runner** (`mise run app|build|dist|icon|status|json`).
   Relaunch with plain `open` — `open -n` force-spawns duplicate instances and
   duplicate menu bar items.
9. The app must live in `~/Applications` (or `/Applications`) for
   `SMAppService` launch-at-login registration, and it does **not** survive
   logout/reboot without that toggle — "the app disappeared" after a weekend
   is almost always this, not a crash.

## Commands

```sh
mise run app        # build + relaunch (the normal dev loop)
mise run status     # quick CLI check of what the app will show
./ai-cache-bar.py --json | python3 -m json.tool   # inspect the full contract
./ai-cache-bar.py --calibrate                     # force codex curve remeasure
```

Verification patterns that work (and were used to build this):

- **Test notifications without waiting an hour:** back up
  `~/.claude/.ai-cache-bar-state.json`, run `--notify` with env overrides
  (`AI_CACHE_LOOKBACK_MIN=2 AI_CACHE_WARN_SECONDS=3599` turns the current
  session into a fresh "expiring" transition), restore the backup. Expect a
  real banner on screen.
- **Test the cold-tax detector:** write a synthetic transcript into a scratch
  dir under `~/.claude/projects/` with two turns — big `cache_read` two hours
  ago, big `cache_creation` + tiny read now — check `--json`, fire `--notify`
  twice (second run must be silent), then delete the fake and scrub its entry
  from `~/.claude/.ai-cache-bar-titles.json`.

## Hazards

- **NEVER open `claude://resume?session=<uuid>`, especially not against a live
  session.** It is not a navigate: it calls `importCliSession()` →
  `adoptCliSession()`, which **adopts the transcript into a brand-new
  `local_<uuid>` desktop session** — a clone. The deep-link call site passes no
  options, unlike the app's own resume picker (which passes `{title,
  transcript, beforeWrite: liveOwnershipRefusal}`), so the clone arrives
  untitled ("General Coding Session") and there is **no liveness guard**.
  Observed collateral from one firing: a worktree re-lease failure, the
  transcript migrated to a different project dir, and the original
  transcript's **thinking blocks stripped on disk** (irreversible). Evidence:
  `/Applications/Claude.app/Contents/Resources/app.asar` (both call sites) and
  `~/Library/Logs/Claude/main.log` lines `Resume deep link: importing CLI
  session …`, `Stripped thinking blocks from … (954 lines, 71
  empty-after-strip dropped)`, `[CCD] Migrated transcript … from … to …`.
- **`claude://code/continue?session=local_<uuid>`** validates
  (`session === "last" || /^local_[A-Za-z0-9-]{1,64}$/`) but its handler is
  behind an account feature gate that silently returns — log line
  `claudeURLHandler: code entry deep link gated off`. Right semantics, dead
  route.
- **Never parse Claude transcripts naively.** One API response is written as
  one line **per content block**, each repeating the same `message.usage` —
  totals come out ~2.5× too high unless you dedupe by `message.id`. Streaming
  partials/retries share a `requestId` (keep the last per id).
  `isSidechain: true` = subagent (own cache prefix — excluded from session
  rows, but ~34% of real token spend, so **included** in plan calibration).
  `model: "<synthetic>"` entries carry zero usage — skip.
- **Transcripts are multi-MB.** The collector must stay on `tail_lines()`
  (bounded reads); full-file scans are allowed only once per session for
  titles, cached in `~/.claude/.ai-cache-bar-titles.json`.
- Codex `session_meta` has its `type` at the **top level** of the line;
  `token_count` has it **nested** under `payload.type`. Handle both; they
  coexist in the same file.

## Platform facts and evidence

### Claude Code / desktop app

| Fact | Evidence / source |
|---|---|
| Prompt-cache TTL is **1 hour**, refreshed every turn | Every local transcript reports `ephemeral_1h_input_tokens`, never the 5m tier (`~/.claude/projects/**/*.jsonl`). Pricing (1.25× write, 0.1× read) per Anthropic's prompt-caching docs. |
| Chat titles live **in the transcript** | `{"type":"custom-title"}` / `{"type":"ai-title"}` entries; custom wins; matches the desktop app's list exactly. |
| Desktop session ids (`local_<uuid>`) ≠ transcript `sessionId` | Session store: `~/Library/Application Support/Claude/claude-code-sessions/<org>/…/local_*.json` (`cliSessionId` field). Only on-disk mapping from a transcript: `git-worktrees.json` → worktree path → `leasedBy`. Used here **only** to collapse a resumed chat's several transcripts into one row. |
| An adopted (cloned) session and the original **share one `.jsonl`** | Two store records with the same `cliSessionId` after the resume incident; archiving one is safe (demonstrated), deletion leaves a tombstone and keeps the file (inferred — prefer archive). |
| No safe deep link into an existing chat | See Hazards. |
| Plan usage is sampled locally | `~/Library/Application Support/Claude/plan-usage-history.json`: ~5-min samples `{"t": epoch_ms, "u": {"fh": pct, "sd": pct}}` — five-hour / seven-day limits as whole percentages. |
| The server's rate-limit verdict lands in transcripts | `quotaLimits {status, rateLimitType, resetsAt (epoch s), overageStatus, overageDisabledReason}`. `org_level_disabled` overage ⇒ 100% is a hard stop. |
| `statusLine` is CLI-only | The desktop app ignores it — upstream request anthropics/claude-code#41456. |
| Native notifications need better than ad-hoc signing | `UNUserNotificationCenter.requestAuthorization` → `UNErrorDomain Code=1` even Apple-Development-signed, `lsregister`ed, fresh bundle id. Hence the terminal-notifier fallback; a Developer ID identity flips the native path on by itself. |

### The plan-limit calibration (2026-08-28)

Fitted against 30 days of `plan-usage-history.json` samples joined to local
transcripts (message.id-deduped, subagents included):

```
U = Σ_model w × (input + cache_write_5m + 1.6 × cache_write_1h + 14 × output)
w: fable 2.0 · opus 1.0 · sonnet 0.4 · haiku 0.2
five-hour %  ≈ U / 179 000     seven-day % ≈ U / 1 500 000
```

- Within a five-hour window, `fh` is linear in U (R² ≈ 1.000); six fully
  sampled windows agree to ±4.5%; leave-one-out MAE 6.5%.
- **Cache reads weigh 0** — 94% of raw tokens, and the fit degrades
  monotonically as their weight rises (OLS coefficient slightly negative).
  This single fact drives the product: warm chats compact for ~0.3pp, cold
  ones for ~2pp.
- fable/opus = 2.0 was recovered **by the fit**, matching the list-price input
  ratio; sonnet/haiku weights rest on <1% of the data.
- Output multiplier and divisor are only jointly identified (14×/179k ≡
  18×/206k) — treat the pair as one calibration.
- The seven-day divisor rests on 3 windows disagreeing by 44% — order of
  magnitude only; never alert on it.
- These are **one account's constants** (`AI_CACHE_5H_PER_PCT` etc. to
  override). Re-derivation recipe lives in README's calibration section.

### Codex

| Fact | Evidence / source |
|---|---|
| A resume spawns a **new rollout file**; all carry the same `session_id` | `~/.codex/sessions/<y>/<m>/<d>/rollout-<ts>-<session_id>[_<sub>].jsonl`, `session_meta` head line. One real session showed as 5 files in 4h — dedupe by id. |
| Chat names live in `~/.codex/session_index.jsonl` | `{"id", "thread_name", "updated_at"}`, last entry wins; covers auto-generated names and user renames. Rollouts never carry a title. |
| Per-call usage | `token_count` events → `payload.info.last_token_usage.{input_tokens, cached_input_tokens, …}`. |
| Eviction curve (this account, 1,019 pairs, 2026-08-28) | ~100% hits ≤10 min idle, ~70% between 10 and ~43 min, none ≥2 h. Matches OpenAI's prompt-caching guidance ("typically cleared after 5–10 minutes of inactivity, always within one hour"). No contractual TTL exists — hence estimate-only display. |
| Self-calibration | `_measure_codex()`: (idle gap → hit?) pairs, prompts ≥5k tokens only; `warm_s` = last gap bucket with hit-share ≥80% (floor 300s), `dead_s` = longest observed survival +60s (cap 2h), `maybe_pct` = hit-share in between. Cached in `~/.claude/.ai-cache-bar-codex.json`, remeasured on app launch (`--calibrate`) and at most daily otherwise; <100 usable pairs → defaults 600s/3600s. |

### The cold-tax (rewrite) detector

Signature in a transcript's last two turns: previous turn's cached total
>5k, gap ≥ TTL, newest turn's `cache_creation` ≥ `AI_CACHE_REWRITE_MIN` with
`cache_read` < 50% of the previous total. Priced as
`w_model × wrote × 1.6 / 179 000` pp of the five-hour limit. Notify once per
event, only while fresh (≤30 min).

## Distribution

Signing picks up a `Developer ID Application` or `Apple Development` identity
from the keychain (`CODESIGN_IDENTITY` overrides). Apple Development is enough
to run and to keep launch-at-login, but **not** for native notifications, and
Gatekeeper blocks the zip on other Macs (right-click → Open). Real
distribution = paid Developer ID + `xcrun notarytool`.
