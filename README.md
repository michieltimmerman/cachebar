# CacheBar

macOS menu bar app that tracks **prompt-cache warmth** and **plan-limit budget**
across the Claude Code sessions on this machine — plus a couple of CLI surfaces
over the same data.

Everything is derived from files the tools already write locally. No API calls,
no network, no credentials.

```
🔥 44m                                    ← menu bar: hottest session's countdown
──────────────────────────────
🔥 Cloud cost calculator sizing  · 44m left · 384k
⚠️ Renovate automerge config     · 8m left · 462k
❄️ MR !5573 — ML module status   · cold 4h51m — rewrites 217k
──────────────────────────────
compacting 5 chats ≈ 13.3% of the 5h limit · 85% left
2 cold → 12.0pp of it; reopening one before it chills makes it free
```

Notifications fire when a session is about to go cold (default: 10 minutes
before), when it has gone cold, when a turn in a cold chat just paid the tax —
"Rewrote 390k cached tokens after 1h57m idle — ≈7.0% of the 5h limit" — and once
when compacting all open chats would no longer fit in what's left of the
five-hour limit.

## Why

Claude Code caches the conversation prefix with a **1-hour ephemeral TTL** (every
transcript on this machine reports `ephemeral_1h_input_tokens`; the 5-minute tier
is never used). Each turn refreshes the TTL. Let a chat idle past the hour and the
next message rewrites the whole prefix at 1.25× base input price instead of
reading it at 0.1× — and, more importantly for plan users, cache **reads don't
count against the plan limits at all** while rewrites very much do. Keeping warm
chats warm is close to free; letting them chill is not.

## Layout

| File | What it is |
|---|---|
| `ai-cache-bar.py` | The single source of truth. Collects sessions, derives state, titles, and the plan budget. Emits `--json` (what the app consumes), `--text`, `--swiftbar`, `--notify`. Stdlib-only `/usr/bin/python3` so it runs under launchd/SwiftBar's minimal PATH. |
| `Package.swift`, `Sources/CacheBar/` | The app, a plain SwiftPM executable: SwiftUI `MenuBarExtra` that polls the Python every 15 s. All logic stays in the Python so the rules never fork between surfaces. `swift build` works; so does opening the package in Xcode (`xed .`). |
| `packaging/build.sh` | Release-builds via SwiftPM and assembles `CacheBar.app`: Info.plist, icon, codesigning, and `ai-cache-bar.py` bundled into Resources so a build deploys both halves. |
| `packaging/make-icns.sh`, `render-icon.swift` | Regenerate the committed `CacheBar.icns` (only needed when the design changes). |
| `cache-ttl.sh` | Older single-session tool: countdown, `--watch`, `--history` of cache invalidations, statusline widget via `--stdin`. Needs `jq`. |

## Install

Requires macOS 14+, the Xcode toolchain, and optionally
[`terminal-notifier`](https://github.com/julienXX/terminal-notifier) for
notifications (see below).

```sh
mise run app        # build and (re)launch CacheBar.app
mise run status     # one-line-per-session summary in the terminal
mise run dist       # shareable dist/CacheBar.zip
```

Without mise: `packaging/build.sh && open -n ~/Applications/CacheBar.app`.

The menu has a **Launch at login** toggle (`SMAppService`; it appears under
System Settings → General → Login Items like any other app).

Sharing the zip with another Mac: the app is signed with an Apple Development
identity, not notarized, so Gatekeeper will block the first launch — right-click
→ Open once. Proper distribution needs a paid Developer ID plus
`xcrun notarytool`; `packaging/build.sh` picks up such an identity automatically
via `CODESIGN_IDENTITY`, at which point native notifications also switch on.

Alternative surfaces, no app needed:

- **SwiftBar/xbar**: symlink `ai-cache-bar.py` into your plugin folder as
  e.g. `cachebar.30s.py`.
- **launchd**: run `ai-cache-bar.py --notify` on an interval; it posts
  notifications only on state *transitions*, so polling is quiet.

## Configuration

All knobs are environment variables read by `ai-cache-bar.py`:

| Variable | Default | Meaning |
|---|---|---|
| `AI_CACHE_TTL_SECONDS` | `3600` | Claude cache TTL to assume |
| `AI_CACHE_CODEX_TTL_SECONDS` | `600` | Codex estimated TTL (measured; see codex section) |
| `AI_CACHE_WARN_SECONDS` | `600` | "Expiring" warning lead time |
| `AI_CACHE_LOOKBACK_MIN` | `240` | How far back to look for sessions |
| `AI_CACHE_MAX_ROWS` | `10` | Rows shown per surface |
| `AI_CACHE_NOTIFY_MAX_AGE` | `7200` | Don't notify about sessions idle longer than this |
| `AI_CACHE_5H_PER_PCT` | `179000` | Weighted tokens per 1% of the five-hour limit (see calibration) |
| `AI_CACHE_7D_PER_PCT` | `1500000` | Same for the seven-day limit (much less certain) |
| `AI_CACHE_COMPACT_OUT` | `4000` | Assumed summary size of one compaction |
| `AI_CACHE_REWRITE_MIN` | `25000` | Smallest prefix rewrite worth a cold-tax notification |
| `CACHEBAR_SCRIPT` | *(bundled)* | App only: override which script the app polls |

## Data sources

- `~/.claude/projects/**/*.jsonl` — Claude Code transcripts. Last main-chain
  entry's `message.usage` gives cache size and turn time; `custom-title` /
  `ai-title` entries give the chat's name (custom wins). Subagent transcripts
  (`*/subagents/*`) have their own cache prefix and are excluded from rows.
- `~/Library/Application Support/Claude/plan-usage-history.json` — the desktop
  app's ~5-minute samples of `{"fh": pct, "sd": pct}`: five-hour and seven-day
  plan usage as whole percentages.
- `~/Library/Application Support/Claude/git-worktrees.json` — maps worktrees to
  the desktop-app session leasing them; used only to collapse a resumed chat's
  several transcripts into one row.
- `quotaLimits` entries inside transcripts — the server's own rate-limit verdict
  (`rateLimitType`, `resetsAt`), surfaced when a limit is actively capping.

## The plan-budget calibration

`plan-usage-history.json` gives percentages; converting a token estimate into
"percent of the limit" needed an empirical fit. Against 30 days of samples
(2026-08-28), usage within a five-hour window is linear (R² ≈ 1.000) in:

```
U = Σ over models of  w × (input + cache_write_5m + 1.6 × cache_write_1h + 14 × output)

w:  fable 2.0 · opus 1.0 · sonnet 0.4 · haiku 0.2
five-hour percent  ≈ U / 179 000      seven-day percent ≈ U / 1 500 000
```

Findings that shape the tool:

- **Cache reads carry weight 0.** They were 94% of raw tokens in the calibration
  data and the fit degrades monotonically as their weight rises. This is why a
  warm chat compacts for ~0.3pp while a cold one costs ~2pp.
- The fable/opus weight ratio came out of the fit as exactly **2.0** — the
  list-price input ratio — without being told.
- The output multiplier and divisor are only jointly identified (14×/179k and
  18×/206k fit equally well); treat the pair as one calibration.
- The **seven-day** figure rests on 3 windows that disagree by 44% — order of
  magnitude only. The app doesn't alert on it.

These constants are one account's fit. To recalibrate, dedupe transcript entries
by `message.id` first (Claude Code writes one line per content block with
`usage` repeated — skipping this inflates every total ~2.5×), include subagent
transcripts (~⅓ of real spend), and regress per-window token sums against the
window's peak `fh`.

## Why nothing is clickable

Rows and notifications are information, not actions: there is no safe deep link
into an existing desktop-app chat, so there is nothing useful to open. Both
routes in the app were tried:

- `claude://code/continue?session=local_<uuid>` has the right semantics but its
  handler is behind an account feature gate that silently returns
  (`claudeURLHandler: code entry deep link gated off` in the app's log).
- `claude://resume?session=<transcript-uuid>` is **not** a navigate. It calls
  `importCliSession()` → `adoptCliSession()`, which **adopts the transcript into
  a brand-new session** — untitled (shows as "General Coding Session") and with
  no liveness guard, unlike the app's own resume picker. Firing it at a live
  session **clones the chat**; in testing it also migrated the transcript to a
  different project directory and stripped its thinking blocks on disk. Don't.

## Notifications need a real signing identity

`UNUserNotificationCenter.requestAuthorization` returns `UNErrorDomain Code=1`
for ad-hoc-signed apps, even ones registered with LaunchServices. An **Apple
Development** certificate (free personal team) is enough; `build.sh` picks one up
from the keychain automatically, or set `CODESIGN_IDENTITY`. Without one, the app
falls back to `terminal-notifier` (which keeps click-to-reveal via `-execute`),
or `osascript` as a last resort.

## Also here: codex

`~/.codex/sessions/**/*.jsonl` rows show cached tokens, hit-rate, and an
**estimated** eviction countdown, marked with a `~`. OpenAI's implicit caching
has no contractual TTL, so the window was measured from this account's own
history (1,019 call pairs): hits are ~100% up to 10 minutes idle, roughly
two-in-three between 10 and 30 minutes, and gone by 2 hours — matching OpenAI's
"5–10 minutes typical, up to one hour" guidance. The countdown runs against the
reliable 10-minute window (`AI_CACHE_CODEX_TTL_SECONDS`); past it the row says
"likely evicted" rather than pretending certainty, and estimated TTLs shape the
display but never fire notifications.

A resume spawns a new rollout file, so rows dedupe by the `session_meta` head
line's `session_id`. Chat names (auto-generated and user renames alike) live in
`~/.codex/session_index.jsonl` as `thread_name`, keyed by that same id; unnamed
chats fall back to a cwd@branch label.

## License

MIT — see [LICENSE](LICENSE).
