# CacheBar

A macOS menu bar app that tracks **prompt-cache warmth** and **plan-limit budget**
across the Claude Code sessions on this Mac, plus a few CLI surfaces over the
same data.

Everything is derived from files Claude Code, the Claude desktop app and Codex
already write locally. No API calls, no network, no credentials. Contributors and
AI agents: **[AGENTS.md](AGENTS.md)** carries the architecture rules, the hazards,
and every platform fact this tool rests on with its evidence. Read it before
changing anything.

**[Download the latest release](../../releases/latest)**: macOS 14+, Apple
silicon and Intel.

```
🔥 3m                                    ← menu bar: the live chat closest to going cold
Prompt cache · 6 warm / 10 recent
──────────────────────────────
🧹  Summarise design doc  ·  compacted 6m ago — next turn writes a fresh prefix
🔥  Quick lint fixes  ·  3m left · 47k
🟢  Sketch onboarding flow  ·  ~5m left · 38k · 90% hit
⚠️  Draft release notes  ·  6m left · 120k
🔥  Add export command  ·  42m left · 110k
🔥  Migrate config loader  ·  48m left · 255k
🔥  Refactor parser tests  ·  52m left · 384k
🟡  Benchmark JSON encoder  ·  maybe still warm (~50%) · idle 25m · 23% hit
🔴  codex inventory@main  ·  likely evicted — idle 1h40m · 83% hit
❄️  Tune flaky integration test  ·  cold 2h10m — rewrites 217k
──────────────────────────────
compacting 7 chats ≈ 6.1% of the 5h limit · 72% left
1 cold → 3.4pp of it; reopening one before it chills makes it free
```

(The made-up chats of the test fixture, `tests/make-fixtures.py`.)

Notifications fire when a chat is about to go cold (10 minutes before by
default), when it has gone cold, when a turn in a cold chat just paid the tax
("Rewrote 252k cached tokens after 2h43m idle — ≈6.8% of the 5h limit."), and
once when compacting all open chats would no longer fit in what's left of the
five-hour limit.

## Why

Claude Code caches each conversation's prefix, and every turn refreshes the
cache's TTL. The TTL is chosen per request: chats mostly use the **1-hour** tier,
but some switch to the **5-minute** tier mid-chat and subagents always use it, so
CacheBar reads each chat's tier from its newest cache write. Let a chat idle past
its TTL and the next message rewrites the whole prefix, at 2× the base input
price for the 1-hour tier (1.25× for the 5-minute one), instead of reading it at
0.1×. More importantly for plan users, cache **reads don't count against the
plan limits** (see [the calibration](#the-plan-budget-calibration)) while
rewrites very much do. Keeping warm chats warm is close to free; letting them
chill is not.

## Requirements

- macOS 14 or later
- Claude Code, CLI or desktop app. The plan budget needs the desktop app, which
  records plan usage; codex rows appear when `~/.codex` exists.
- Python 3.6 or newer for the bundled script. Apple's Command Line Tools have one
  (`xcode-select --install`); Homebrew, python.org, MacPorts, mise, asdf and pyenv
  installs are found too. See [Finding Python](#finding-python).
- Xcode or the Command Line Tools (Swift 5.9+) to build
- Optional: [mise](https://mise.jdx.dev) for the task shortcuts below

## Install

### Download

1. Download **CacheBar.zip** from the [latest release](../../releases/latest).
   It's a universal build that runs on both Apple silicon and Intel.
2. Unzip it and move **CacheBar.app** to `/Applications` (or `~/Applications`).
3. Open it. If the release notes say the build isn't notarized, macOS refuses the
   first launch (right-click → Open no longer gets past this on macOS 15). Go to
   **System Settings → Privacy & Security**, click **Open Anyway** once, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/CacheBar.app
   ```
4. Turn on **Launch at login** in its menu or Settings. This only works while the
   app is in an Applications folder. Without it CacheBar doesn't come back after
   a logout or restart.

### Build from source

```sh
git clone https://github.com/michieltimmerman/cachebar.git && cd cachebar
packaging/build.sh                 # or: mise run build
open ~/Applications/CacheBar.app
```

`build.sh` installs into `~/Applications` and bundles `ai-cache-bar.py` into the
app, so after editing the script, rebuild (`mise run app` builds and relaunches).
If your keychain has a Developer ID or Apple Development identity it signs with
that, otherwise ad-hoc; all of them run fine when built locally (see
[Notifications](#notifications) for the one difference).

### Without the app

- **SwiftBar/xbar**: symlink `ai-cache-bar.py` into your plugin folder as e.g.
  `cachebar.30s.py`.
- **launchd**: run `ai-cache-bar.py --notify` on an interval. It posts only on
  state *transitions* (kept in `~/.claude/.ai-cache-bar-state.json`), so polling
  is quiet; its first run only records where every chat stands.

Both run the script through its `#!/usr/bin/python3` line, which needs the
Command Line Tools; otherwise invoke it with another python3.

## What the menu shows

| Menu bar | Meaning |
|---|---|
| `🔥 44m` | the live chat closest to going cold, and its time left (`⚠️` inside the warning lead, `🟢 ~5m` for a codex estimate) |
| `❄️ 2h10m` | no chat is warm; how long the most recent one has been idle |
| `🫥` | no chats in the look-back window |
| `…` | reading for the first time |
| `⚠️ no Python` | no usable Python 3; the menu says what to do |
| `⚠️`, or `🔥 44m ?` | the script failed; the menu says why and keeps the last good data, marked "Showing data as of 3m ago" |

| Row | Meaning |
|---|---|
| 🔥 | warm: exact time left on its cache, and the cache's size |
| ⚠️ | expiring: inside the warning lead |
| ❄️ | cold: the next turn rewrites this many tokens |
| 🧹 | compacted since its last turn: the summary isn't cached until the next turn |
| 🟢 🟡 🔴 | codex, estimated (see [codex](#also-here-codex)) |

Below the rows, the budget: what compacting every open Claude chat would cost
against the five-hour limit, how much of the limit is left, and how much of the
cost comes from cold chats. It adds "(usage as of 2h ago)" when the newest plan
sample is over 30 minutes old and says "(plan usage unknown)" when there is none
from the last five hours. Extra lines appear while the budget still uses the
default calibration, and when a limit is capping you right now (with its reset
time).

The items are **Launch at login**, **Refresh now**, **Send test notification**,
**Settings…** (⌘,) and **Quit CacheBar**. The rows themselves can't be clicked;
see [Why nothing is clickable](#why-nothing-is-clickable).

## Notifications

The chat title is the banner's headline and the state goes in the body; a chat's
newer banner replaces its own older one. They fire only for Claude chats idle
less than two hours, only on changes (never for what was already true at launch),
and never for codex estimates. Turn them off in Settings or with
`--notifications off`.

How a banner is delivered depends on the app's signature:

- **Developer ID builds** (notarized releases) use `UNUserNotificationCenter`,
  with the usual permission prompt.
- **Every other build** (ad-hoc releases and local builds, Apple Development
  signed ones included) is refused that route by macOS: `UNErrorDomain Code=1`,
  "Notifications are not allowed for this application". CacheBar then posts
  through the deprecated `NSUserNotificationCenter`, which asks for no permission
  and still shows the banner as CacheBar, with its icon.
- A bare `swift run` binary has no app bundle for either, and uses `osascript`.

**Send test notification** checks delivery end to end. The CLI's `--notify`
always uses `osascript`, so its banners don't replace each other per chat.

## Settings

**Settings…** (⌘,) in the menu:

- **Notifications**, and **Warn before a chat goes cold**: 2 to 30 minutes
  before a 1-hour cache lapses (default 10). A 5-minute chat gets the same share
  of its TTL: 50 seconds at the default.
- **Rows in the menu** (default 10) and **Look back** (default 4 hours): which
  chats are listed.
- **Python**: the one in use and where it came from, an **Override** (Choose… /
  Clear) and **Detect again**.
- **Launch at login**, and the version.

Settings are saved in the app's defaults (`com.michieltimmerman.cachebar`, keys
`notifications`, `warnMinutes`, `maxRows`, `lookbackHours`, `CACHEBAR_PYTHON`), so
`defaults write` works too. The numbers reach the script as its `AI_CACHE_*`
variables.

### Command-line arguments

Every setting can also be given for a single run. An argument wins over the
environment, which wins over Settings. The Settings window shows such a value
greyed out with what set it, and arguments are never saved:

```sh
open -a CacheBar --args --warn-minutes 5 --max-rows 15
~/Applications/CacheBar.app/Contents/MacOS/CacheBar --status
```

| Argument | Setting | Environment variable |
|---|---|---|
| `--python PATH` | Python override | `CACHEBAR_PYTHON` |
| `--notifications on\|off` | Notifications | |
| `--warn-minutes N` | Warn before a chat goes cold | `AI_CACHE_WARN_SECONDS` (seconds) |
| `--max-rows N` | Rows in the menu | `AI_CACHE_MAX_ROWS` |
| `--lookback-hours N` | Look back | `AI_CACHE_LOOKBACK_MIN` (minutes) |

Commands that print something and exit:
- `--status`: the Python CacheBar would use, its settings, then
  `ai-cache-bar.py --text`;
- `--version` and `--help`.

## Finding Python

A GUI app gets launchd's minimal `PATH`, and `/usr/bin/python3` is only a stub
until the Command Line Tools are installed: running it opens their install dialog
instead. So CacheBar looks for a python3 itself and vets each candidate with a
short run before using it, in this order:

1. an explicit choice: `--python`, then `CACHEBAR_PYTHON`, then Settings. It
   decides alone: when it doesn't work, the menu says so rather than quietly
   running another Python.
2. the one found last time
3. the active developer directory's (`xcode-select -p`: Xcode or the Command Line
   Tools)
4. Homebrew (`/opt/homebrew`, `/usr/local`), python.org, MacPorts, then mise,
   asdf and pyenv installs, newest version first

With none, the menu bar shows `⚠️ no Python` and the menu suggests
`xcode-select --install` or picking one in Settings. It looks again every 15
seconds, so a fresh install is picked up by itself, and it searches again when the
Python in use disappears (say, after a Homebrew or mise upgrade).

## Configuration

Everything the app needs is in the **Settings** window or the
[arguments](#command-line-arguments). The script's knobs are environment
variables; the app passes its own environment through, with the settings layered
on top.

| Variable | Default | Meaning |
|---|---|---|
| `AI_CACHE_TTL_SECONDS` | *(per chat)* | Force one cache TTL on every Claude chat instead of each chat's own tier (1 h, 5 min, or 3600 when unknown) |
| `AI_CACHE_WARN_SECONDS` | 600 | "Expiring" lead time for a 1-hour cache; shorter tiers get the same share of their TTL (as is when `AI_CACHE_TTL_SECONDS` pins the TTL) |
| `AI_CACHE_LOOKBACK_MIN` | `240` | How far back to look for chats |
| `AI_CACHE_MAX_ROWS` | `10` | Rows shown by `--text`/`--swiftbar`, and by the app's menu (`--json` lists every chat) |
| `AI_CACHE_TAIL_BYTES` | `262144` | How much of each transcript's tail to read |
| `AI_CACHE_NOTIFY_MAX_AGE` | `7200` | No notifications about chats idle longer than this (script and app) |
| `AI_CACHE_5H_PER_PCT` | *(self-calibrated; fallback 179000)* | Weighted tokens per 1% of the five-hour limit; setting it skips the fit |
| `AI_CACHE_7D_PER_PCT` | *(1500000 scaled like the 5h divisor)* | Same for the seven-day limit (much less certain) |
| `AI_CACHE_COMPACT_OUT` | `4000` | Assumed summary size of one compaction |
| `AI_CACHE_REWRITE_MIN` | `25000` | Smallest prefix rewrite worth a cold-tax notification |
| `AI_CACHE_CODEX_TTL_SECONDS` | *(self-calibrated)* | Override the measured codex reliably-warm window |
| `AI_CACHE_NOW` | *(real clock)* | Pin the clock (epoch seconds), for tests and demo data |
| `AI_CACHE_INLINE_FIT` | `1` | `0`: never remeasure a stale calibration inline, only on `--calibrate` (the app sets this for its polls) |

App only:

| Variable | Effect |
|---|---|
| `CACHEBAR_PYTHON` | python3 to run the script with (as `--python` / Settings) |
| `CACHEBAR_SCRIPT` | script to poll instead of the bundled copy |
| `CACHEBAR_DEBUG=1` | one line per event on stderr: `python:`, `poll:`, `notify:`, `error:` |
| `CACHEBAR_NO_BANNERS=1` | log notifications (with `CACHEBAR_DEBUG`) but deliver none |
| `CACHEBAR_TIME_SCALE=N` | poll N× as often (tests) |
| `CACHEBAR_TEST_NOTIFICATION=1` | send one test notification a few seconds after launch |
| `CACHEBAR_BUNDLE_ID`, `CODESIGN_IDENTITY`, `VERSION`, `UNIVERSAL=1`, `SHARED=1` | build time (`packaging/build.sh`): bundle id, signing identity, version, universal binary; `SHARED=1` (dist, releases) refuses any identity but a Developer ID or ad-hoc |

## Data sources

- `~/.claude/projects/**/*.jsonl`: Claude Code transcripts. The newest main-chain
  turn's `message.usage` gives cache size and turn time, and the newest turn that
  wrote cache gives the TTL tier (`cache_creation.ephemeral_1h_input_tokens` →
  1 h, `ephemeral_5m_input_tokens` → 5 min). `model: "<synthetic>"` entries
  (compaction stubs, rate-limit rejections) are not turns and are skipped.
  `custom-title` / `ai-title` entries give the chat's name (custom wins). A
  compaction writes no usage of its own, so an `isCompactSummary` entry newer than
  the last turn marks the chat 🧹 compacted: its old prefix is gone and the
  summary that replaced it isn't cached until the next turn. Subagent transcripts
  (`*/subagents/*`) have their own cache prefix and are left out of the rows, but
  counted in the plan calibration.
- `~/Library/Application Support/Claude/plan-usage-history.json`: the desktop
  app's samples of `{"fh": pct, "sd": pct}`, five-hour and seven-day plan usage as
  whole percentages. It samples only while it's open.
- `~/Library/Application Support/Claude/git-worktrees.json`: maps worktrees to
  the desktop-app session leasing them; used only to collapse a resumed chat's
  several transcripts into one row.
- `quotaLimits` entries inside transcripts: the server's own rate-limit verdict
  (`rateLimitType`, `resetsAt`), shown while a limit is actively capping.
- `~/.codex/sessions/**/*.jsonl` and `~/.codex/session_index.jsonl`: see
  [codex](#also-here-codex).

The script writes only small caches next to the transcripts:
`~/.claude/.ai-cache-bar-titles.json` (chat titles, so a full transcript scan
happens once), `.ai-cache-bar-plan.json` and `.ai-cache-bar-codex.json` (the
calibrations), and `.ai-cache-bar-state.json` (the CLI `--notify`'s last states).

## The plan-budget calibration

`plan-usage-history.json` gives percentages; turning a token estimate into
"percent of the limit" needs a divisor. The weighting comes from a fit against 30
days of samples on the account this was built on (2026-08-28): within a
five-hour window, usage was linear (R² ≈ 1.000) in

```
U = Σ over models of  w × (input + cache_write_5m + 1.6 × cache_write_1h + 14 × output)

w:  fable 2.0 · opus 1.0 · sonnet 0.4 · haiku 0.2
five-hour percent ≈ U / divisor        (that account in August: 179 000)
```

What that fit showed, and the weights still rest on:

- **Cache reads carry weight 0.** They were 94% of raw tokens in the data and the
  fit degrades monotonically as their weight rises. This is why, on that account,
  a warm chat compacted for ~0.3pp of the five-hour limit and a cold one for ~2pp.
- The fable/opus weight came out as exactly **2.0**, the list-price input ratio,
  without being told. The 1.6 on 1-hour cache writes is the list-price ratio of
  1-hour to 5-minute writes (2× vs 1.25×).
- The output multiplier and the divisor are only jointly identified (14×/179k and
  18×/206k fit equally well); treat the pair as one calibration.
- The **seven-day** figure rested on 3 windows that disagreed by 44%: order of
  magnitude only. The app doesn't alert on it.

The divisor differs per plan tier, so CacheBar fits it on each Mac
(`_plan_windows`, `_measure_plan` and `plan_calibration` in `ai-cache-bar.py`):

- Five-hour windows are chained from local usage. A window opens at the first
  response after the previous one closed and ends five hours later, or earlier at
  a sample that reads 0 or drops, which proves the server's window had already
  reset (it was opened elsewhere).
- A window's U is all transcript usage up to its peak sample, subagents included
  and deduplicated by `message.id`. Only windows peaking between 5% and 99% count:
  below that is rounding noise, and 100% is censored by the cap.
- The divisor is a least-squares fit through the origin, weights held fixed, over
  the last 31 days. It needs at least 3 windows and a value between 2,000 and
  5,000,000; otherwise the 179,000 fallback is used and the menu says so.
- The seven-day divisor is scaled by the same ratio. That is an assumption, not a
  measurement.
- The fit is cached in `~/.claude/.ai-cache-bar-plan.json` and redone daily, or
  by `ai-cache-bar.py --calibrate`, which prints `{"plan", "plan_fit", "codex"}`.
  The app runs `--calibrate` itself at launch and then daily, in the background,
  and tells its polls not to remeasure inline (`AI_CACHE_INLINE_FIT=0`), so a long
  scan never runs inside a poll.

Caveats, found on real data (2026-10-31):

- The desktop app samples only while it's open: 57 samples in 30 days on the
  development Mac, not one every few minutes. Few windows end up usable.
- Usage from other devices raises `fh` without leaving local tokens. A window it
  cuts short is detected; extra usage inside a window is not.
- The same account's divisor moved from ~179k per 1% (August) to ~280k (October:
  6 windows, R² 0.956). Treat every fit as approximate.

## Also here: codex

`~/.codex/sessions/**/*.jsonl` rows show cached tokens, hit-rate, and an
**estimated** eviction countdown, marked with a `~`. OpenAI's implicit caching has
no contractual TTL, so nothing past the reliable window is knowable, only likely.
Codex rows therefore use a traffic light instead of claude's deterministic
fire/snow:

- 🟢 inside the measured reliably-warm window, with a `~` countdown
- 🟡 the uncertain zone: "maybe still warm (~70%)", the measured odds
- 🔴 past the longest survival ever observed: "likely evicted"

The curve is **self-calibrated from this Mac's own rollout history**: every
rollout records (idle gap before a call → did it still hit the cache), and the fit
derives the reliable window (bucketed hit-share ≥ 80%), the longest observed
survival, and the hit-share in between. It is cached in
`~/.claude/.ai-cache-bar-codex.json`, redone daily and on each app launch, and
falls back to 10 minutes / 1 hour below 100 usable pairs. On the account this was
built against, 1,019 pairs gave ~100% hits up to 10 minutes idle, ~70% between 10
and ~43 minutes, and none past that, matching OpenAI's "5–10 minutes typical, up
to one hour" guidance. `AI_CACHE_CODEX_TTL_SECONDS` overrides the reliable
window; estimated states shape the display but never fire notifications.

A resume spawns a new rollout file, so rows dedupe by the `session_meta` head
line's `session_id`. Chat names (auto-generated and user renames alike) live in
`~/.codex/session_index.jsonl` as `thread_name`, keyed by that same id; unnamed
chats fall back to a cwd@branch label.

## Why nothing is clickable

Rows and notifications are information, not actions: there is no safe deep link
into an existing desktop-app chat, so there is nothing useful to open. Both routes
in the app were tried:

- `claude://code/continue?session=local_<uuid>` has the right semantics but its
  handler is behind an account feature gate that silently returns
  (`claudeURLHandler: code entry deep link gated off` in the app's log).
- `claude://resume?session=<transcript-uuid>` is **not** a navigate. It calls
  `importCliSession()` → `adoptCliSession()`, which **adopts the transcript into a
  brand-new session**: untitled (shows as "General Coding Session") and with no
  liveness guard, unlike the app's own resume picker. Firing it at a live session
  **clones the chat**; in testing it also migrated the transcript to a different
  project directory and stripped its thinking blocks on disk. Don't.

## Layout

| Path | What it is |
|---|---|
| `ai-cache-bar.py` | The single source of truth: collects sessions, derives state, titles and the plan budget. Emits `--json` (what the app reads), `--text`, `--swiftbar`, `--notify`, `--calibrate`. Stdlib-only Python. |
| `Sources/CacheBar/` | The app, a plain SwiftPM executable: `CacheBar.swift` (menu, polling, notifications), `Python.swift` (finding Python, running the script), `Settings.swift` (Settings window), `Arguments.swift` (command line). All logic stays in the Python so the rules never fork between surfaces. `xed .` opens it in Xcode. |
| `packaging/build.sh` | Release-builds via SwiftPM and assembles `CacheBar.app`: Info.plist, icon, signing, and `ai-cache-bar.py` bundled into Resources. |
| `packaging/release.sh`, `release-secrets.sh` | Cutting a release (see [Releasing](#releasing)). |
| `packaging/make-icns.sh`, `render-icon.swift` | Regenerate the committed `CacheBar.icns` (only when the design changes). |
| `tests/` | Fixture generator, golden script tests, end-to-end tests, demo (see [Development and tests](#development-and-tests)). |
| `cache-ttl.sh` | Older single-session tool: countdown, `--watch`, `--history` of cache invalidations, statusline widget via `--stdin`. Needs `jq`, and still assumes the 1-hour TTL. |

## Development and tests

```sh
mise run app        # build into ~/Applications and (re)launch
mise run test       # build, then tests/script-tests.sh and tests/e2e.sh
mise run demo       # the app on fixture data with neutral titles, for screenshots
mise run status     # ai-cache-bar.py --text on your real data
mise run dist       # dist/CacheBar.zip: universal, ad-hoc unless CODESIGN_IDENTITY is set
```

- **`tests/make-fixtures.py DIR`** builds a deterministic fake HOME: Claude
  transcripts covering every state (5-minute tier, cold tax, compaction, a
  resumed worktree chat, a synthetic rate-limit entry, subagents), 12 days of
  history, plan-usage samples from a simulated server, and codex rollouts. It
  prints the epoch to pin the clock to.
- **`tests/script-tests.sh`** runs `ai-cache-bar.py` against that HOME with the
  clock pinned and a scrubbed environment, and diffs `--json`, `--text` and
  `--swiftbar` against `tests/golden/` for three calibration cases (fitted,
  default, env), plus contract checks the goldens can't override. The goldens are
  the reference for a future Swift port of the script. `--update` rewrites them
  after an intended change; `PYTHON=…` picks the interpreter.
- **`tests/e2e.sh`** runs the real app binary against a fixture HOME.
- **CI**: `.github/workflows/ci.yml` builds a universal app and runs both suites
  on every push to `main` and every pull request.

## Releasing

Releases are cut from a clean `main` that matches GitHub. Both tasks first run
the build, the script tests and the end-to-end tests.

```sh
mise run release 0.1.0         # tag v0.1.0 and push it; GitHub Actions builds and publishes
mise run release-local 0.1.0   # build here and publish with gh (no Actions)
```

The repo has two remotes (`origin` on GitLab, `github` on GitHub); the scripts
use the one whose URL contains github.com, or `REMOTE=<name>`.

- **`release`** triggers `.github/workflows/release.yml`. On a macOS runner it
  builds a universal app, versioned from the tag, and attaches `CacheBar.zip` and
  a SHA-256 checksum to the release. The fixed file name keeps
  `releases/latest/download/CacheBar.zip` a stable link.
- **Signing and notarization:** the build is signed with a Developer ID and
  notarized, so it opens without the Gatekeeper step and gets native
  notifications, when the repository has these secrets:
  - `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY`
  - `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

  Without them, the build is ad-hoc signed and the release notes explain the
  "Open Anyway" step. To set them up:
  1. Join the Apple Developer Program.
  2. Create a **Developer ID Application** certificate (Xcode → Settings →
     Accounts → Manage Certificates).
  3. Export it from Keychain Access as a `.p12` with a password.
  4. Create an app-specific password at account.apple.com.
  5. Run `mise run release-secrets`. It asks for each value and passes it
     straight to `gh secret set`, without writing anything to disk.
- **`release-local`** signs with a Developer ID from your keychain if you have
  one, and ad-hoc otherwise; it doesn't notarize. It never uses an Apple
  Development certificate, because that would put your personal Apple ID in every
  download.

## Provenance

Nearly everything this tool relies on was established empirically
(2026-08-28 → 2026-08-31, revisited 2026-10-31), not from documentation:

- **Claude Code transcripts** (`~/.claude/projects/**/*.jsonl`): TTL tiers and
  when they switch, titles, usage structure and its per-content-block
  duplication, synthetic entries, `quotaLimits` verdicts.
- **Desktop app internals**: deep-link routes and their behavior read out of
  `Claude.app/Contents/Resources/app.asar` and confirmed against
  `~/Library/Logs/Claude/main.log`; session-id mapping from the app's session
  store and `git-worktrees.json`.
- **`plan-usage-history.json`**: plan-usage samples regressed against transcript
  token sums for the calibration.
- **Codex rollouts** (`~/.codex/sessions`) and `session_index.jsonl`: session
  identity, titles, and 1,019 (idle gap → cache hit?) pairs for the eviction
  curve.
- **macOS notifications**: which signatures get `UNUserNotificationCenter`, tested
  on the development Mac.

The only external anchors are OpenAI's prompt-caching guidance ("5–10 minutes
typical, up to one hour") and Anthropic's published cache pricing (5-minute
writes 1.25×, 1-hour writes 2×, reads 0.1× base input). None of this is
contractual. Numbers are one account's fit, behaviors are one app version's.
[AGENTS.md](AGENTS.md) records each fact next to its evidence so drift is
checkable.

## License

MIT — see [LICENSE](LICENSE).

Built by Michiel Timmerman, with [Claude Code](https://claude.com/claude-code) as
a pair programmer.
