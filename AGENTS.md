# AGENTS.md — working on CacheBar

Operating guide for AI agents (and humans) changing this repo. It encodes the
architecture rules and the platform facts this tool is built on, with the
evidence for each. Almost everything here was established **empirically**
(2026-08-28 → 2026-08-31, revisited 2026-10-31 for the first public release) by
reading the files the Claude desktop app, Claude Code, and Codex write locally.
None of it is contractual API behavior unless marked so. Expect drift as those
apps evolve; re-verify a fact before building on it. When a fact turns out wrong,
correct it in place and keep what was believed before, marked superseded.

## Architecture rules

1. **`ai-cache-bar.py` is the single source of truth.** All state derivation
   (warmth, TTL tier, titles, budget, calibrations) happens in the Python.
   `Sources/CacheBar/` is a thin viewer that renders `--json` output. Never derive
   state in Swift; the rules must not fork between the app, `--text`,
   `--swiftbar`, and `--notify`. Text the app writes itself (notification bodies)
   must not assume what the script decides per session, such as the TTL tier.
2. **Stdlib-only Python, 3.6 or newer.** The minimum is set by `json.loads` on
   bytes (3.6). `Pythons.vet` in `Python.swift` and the Settings footer must state
   the same minimum as the script. No jq, no mise, no third-party imports at
   runtime. The `#!/usr/bin/python3` shebang serves SwiftBar and launchd, which
   then need the Command Line Tools.
3. **A build is a deploy of both halves.** `packaging/build.sh` bundles
   `ai-cache-bar.py` into `CacheBar.app/Contents/Resources`. The app's script
   lookup (`scriptPath` in `Python.swift`): `CACHEBAR_SCRIPT` → the bundled copy →
   the checkout a `swift build` binary sits in (`<checkout>/.build/…`) →
   `$HOME/.claude/scripts/ai-cache-bar.py`. **After editing the Python, rebuild
   and relaunch the app** (`mise run app`) or it keeps running the old copy.
4. **Never run `/usr/bin/python3` blindly.** Without the Command Line Tools it is
   a stub that opens their install dialog. `Pythons.resolve` order: an explicit
   setting (`--python` → `CACHEBAR_PYTHON` → Settings), which decides alone and is
   reported as unusable rather than replaced; the remembered last find; the
   developer dir's `python3` (`xcode-select -p`, which never prompts); Homebrew
   (`python3`, then `python3.X` newest first), python.org frameworks, MacPorts,
   mise (`$MISE_DATA_DIR`), asdf, pyenv. Each candidate is vetted by a run (10 s
   timeout). With none: `⚠️ no Python` plus the `xcode-select --install` hint,
   and a new search every tick. A Python that fails to launch mid-run is
   forgotten and searched for again.
5. **Failures are visible, data is kept.** Polls run off the main thread, never
   overlap, and are killed after 20 s. A failed poll (exit status, timeout,
   undecodable JSON) shows its reason at the top of the menu and a `?` in the
   title, and keeps the last good data marked "Showing data as of … ago". The
   optional budget fields decode leniently: one bad field blanks itself instead
   of failing the payload.
6. **Nothing is clickable.** Rows and notifications are information, not
   actions; there is no safe way to open a chat (see Hazards). Do not add links,
   click handlers, or buttons that "open" a session.
7. **Known ≠ estimated, and the UI must say which.** Claude's TTL tier is
   recorded per turn in the transcript → deterministic 🔥/⚠️/❄️ states, exact
   countdowns, notifications. Codex's TTL is a measured estimate → traffic light
   🟢/🟡/🔴, `~` prefixes, the measured odds shown in the uncertain zone, and
   **never** notifications (`ttl_estimate` gates them out in both halves).
8. **Notification shape and delivery.** The chat title is the headline (macOS
   banners give one bold line, ~35 chars; a `"Cache expiring:"` prefix pushes
   real titles out); the state goes in the body. Fire on **transitions only**.
   The app seeds its in-memory maps on the first poll so launch never floods; the
   CLI keeps `~/.claude/.ai-cache-bar-state.json` and seeds it on its first run
   (no state file yet: record, don't announce). Delivery in the app:
   `UNUserNotificationCenter` when granted (any signature, from a normal folder),
   else
   `NSUserNotificationCenter`, else `osascript` for a bare binary without a
   bundle. Both centers get one identifier per session, so a session replaces its
   own earlier banner, never another's. A user who declines the native prompt
   gets no banners at all (no fallback). Both `osascript` paths (the bare binary
   and the CLI `--notify`) pass title and body as argv after `--`, never spliced
   into script text: without `--` a title starting with `-e` is an osascript
   option and can run shell commands. The CLI has no per-session replacement. No
   external notifier tool anywhere.
9. **Settings precedence: argument > environment > Settings.** Arguments
   (`Arguments.swift`) are never saved. Settings live in the app's defaults
   (`com.michieltimmerman.cachebar`) and reach the script as `AI_CACHE_*`
   variables (`Knob` in `CacheBar.swift`: minutes → seconds etc.). Picking the
   script's default clears the setting, so the script's own default applies.
10. **JSON contract:** `--json` emits `{"sessions": [...], "budget": {...}}`;
    the Swift decoder falls back to a bare array for older scripts. Don't break
    either shape. Rows carry `ttl`; the budget carries `calibration`
    (`source`, `windows`, `per_pct_5h`), which the golden contract checks pin.
11. **Deterministic output.** Everything time-relative reads `clock()`
    (`AI_CACHE_NOW` pins it); transcripts are sorted before use; `pct_int` rounds
    half up. `tests/golden/` is the behavioral reference for a future Swift port
    of the script, so keep it reproducible.
12. **mise is the task runner** (`mise run app|build|test|demo|dist|icon|status|json|release|release-local|release-secrets`).
    Relaunch with plain `open`: `open -n` force-spawns duplicate instances and
    duplicate menu bar items.
13. The app must live in `~/Applications` (or `/Applications`) for `SMAppService`
    launch-at-login registration (a translocated copy says so in the menu), and it
    does **not** survive logout/reboot without that toggle. "The app disappeared"
    after a weekend is almost always this, not a crash.

## Commands

```sh
mise run app        # build + relaunch (the normal dev loop)
mise run test       # build, tests/script-tests.sh, tests/e2e.sh
mise run demo       # the app on fixture data with neutral titles (screenshots)
mise run status     # ai-cache-bar.py --text on your real data
./ai-cache-bar.py --json | python3 -m json.tool   # inspect the full contract
./ai-cache-bar.py --calibrate                     # force plan + codex remeasure; prints {"plan","plan_fit","codex"}
~/Applications/CacheBar.app/Contents/MacOS/CacheBar --status   # the Python the app would use, then --text
```

## Testing without touching your real data

Never test by writing into the real `~/.claude` (synthetic transcripts, state
files, title cache). Everything is driven by a fixture HOME instead:

- **Inspect the script on fixture data.**
  ```sh
  tmp=$(mktemp -d); now=$(tests/make-fixtures.py "$tmp/home")
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin AI_CACHE_NOW="$now" ./ai-cache-bar.py --text
  ```
  `--thin-history` gives the default-calibration path, `--no-quota` drops the
  synthetic rate-limit entry, `--now EPOCH` moves the fixture. `env -i` keeps
  your own `AI_CACHE_*` settings out, as `tests/script-tests.sh` does. The
  fixture's docstring lists what each chat exercises.
- **Notifications without waiting an hour.** Run `--notify` the same way. The
  first run only seeds the state file (in the fixture home); move the clock with
  `AI_CACHE_NOW` on the next run to see transitions post real banners, and a run
  with an unchanged clock must be silent.
- **New behavior** (a detector, a state): add the case to
  `tests/make-fixtures.py`, run `tests/script-tests.sh --update`, and review the
  golden diff line by line before committing it. The contract checks catch a
  broken calibration path even when the goldens are rewritten.
- **The app.** It takes its home from `$HOME`, so the same fixture works for it
  (its Settings still come from your real defaults).
  Test hooks: `CACHEBAR_DEBUG=1` (one `python:`/`poll:`/`notify:`/`error:` line
  per event on stderr), `CACHEBAR_NO_BANNERS=1` (log, don't deliver),
  `CACHEBAR_TIME_SCALE=N` (poll N× as often), `CACHEBAR_SCRIPT`,
  `CACHEBAR_PYTHON`, `CACHEBAR_TEST_NOTIFICATION=1`. `tests/e2e.sh` and
  `tests/demo.sh` are the worked examples.

## Hazards

- **NEVER open `claude://resume?session=<uuid>`, especially not against a live
  session.** It is not a navigate: it calls `importCliSession()` →
  `adoptCliSession()`, which **adopts the transcript into a brand-new
  `local_<uuid>` desktop session**: a clone. The deep-link call site passes no
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
  behind an account feature gate that silently returns (log line
  `claudeURLHandler: code entry deep link gated off`). Right semantics, dead
  route.
- **Never parse Claude transcripts naively.** One API response is written as
  one line **per content block**, each repeating the same `message.usage`;
  totals come out ~2.5× too high unless you dedupe by `message.id`. Streaming
  partials/retries share a `requestId` (keep the last per id).
  `isSidechain: true` = subagent (own cache prefix, excluded from session rows,
  but ~34% of real token spend, so **included** in plan calibration).
- **Skip `model: "<synthetic>"` entries by model, not by `requestId`.** They
  carry all-zero usage. Compaction stubs have no `requestId`, but API-error
  notices such as rate-limit rejections do, so the `requestId` filter alone lets
  them through; until 2026-10-31 such a rejection was taken as the chat's last
  turn (0 cached, countdown restarted at the rejection).
- **Never assume the 1-hour TTL.** Read the tier from the newest turn that wrote
  cache (`cache_ttl()`); chats switch tiers mid-conversation and subagents use
  5 minutes. The warn lead (`warn_for()`, also what the Settings picker and
  `--warn-minutes` set) is meant for a 1-hour cache and scales with the TTL for
  shorter tiers; only a pinned `AI_CACHE_TTL_SECONDS` uses it as is.
- **A compaction writes no usage entry.** `/compact` appends a
  `{"isCompactSummary": true}` user entry (and a `<synthetic>` assistant stub
  with all-zero usage and no `requestId`). So between the compaction and the next
  real turn, the newest usage entry is the **pre-compaction** turn: reporting it
  gives the old prefix size and a countdown anchored before the compaction
  (observed: 13 min stale, 318k instead of 75k) and inflates the budget line.
  Hence the `compacted` state: track the newest `isCompactSummary` timestamp and
  compare it to the last usage entry's. The same marker also suppresses the
  cold-tax detector: the prefix rewrite on the first post-compaction turn is
  the compaction's doing, not idleness.
- **Transcripts are multi-MB.** The collector must stay on `tail_lines()`
  (bounded reads); full-file scans are allowed only once per session for
  titles, cached in `~/.claude/.ai-cache-bar-titles.json`, and in the
  calibrations, which `cached_fit()` limits to once a day (a claim stamp keeps
  concurrent polls from scanning too; an unwritable cache means defaults, not a
  rescan every poll).
- **Never sign a release with an Apple Development certificate.** Its signature
  carries the developer's personal Apple ID into every download, and it gains
  nothing over ad-hoc (no notarization, no native notifications).
- Codex `session_meta` has its `type` at the **top level** of the line;
  `token_count` has it **nested** under `payload.type`. Handle both; they
  coexist in the same file.

## Platform facts and evidence

### Claude Code / desktop app

| Fact | Evidence / source |
|---|---|
| Prompt-cache TTL is chosen **per request**: mostly 1 h, sometimes 5 min; refreshed every turn | 2026-08-28: every local transcript then reported `ephemeral_1h_input_tokens`, never 5m, so a fixed 1 h was assumed (**superseded**). 2026-10-31: a scan of every local transcript's `cache_creation` split, deduped by `message.id`: 8 of the ~400 main transcripts wrote both tiers (switched mid-chat), none was 5m-only; every one of the 1,699 subagent transcripts that wrote cache used 5m. Both tiers in one turn was never seen. |
| Cache pricing | 5m-tier writes 1.25× base input, 1h-tier writes 2×, reads 0.1× (Anthropic's prompt-caching pricing). Earlier docs said 1.25× for the 1h tier (**wrong**). The calibration's 1.6 weight on 1h writes is exactly 2 / 1.25. |
| Rate-limit rejections are `<synthetic>` entries with a `requestId` | 2026-10-31: 147 synthetic entries with a `requestId` in local main transcripts, 61 of them carrying `quotaLimits`; 69 without (compaction stubs). |
| Chat titles live **in the transcript** | `{"type":"custom-title"}` / `{"type":"ai-title"}` entries; custom wins; matches the desktop app's list exactly. |
| Desktop session ids (`local_<uuid>`) ≠ transcript `sessionId` | Session store: `~/Library/Application Support/Claude/claude-code-sessions/<org>/…/local_*.json` (`cliSessionId` field). Only on-disk mapping from a transcript: `git-worktrees.json` → worktree path → `leasedBy`. Used here **only** to collapse a resumed chat's several transcripts into one row. |
| An adopted (cloned) session and the original **share one `.jsonl`** | Two store records with the same `cliSessionId` after the resume incident; archiving one is safe (demonstrated), deletion leaves a tombstone and keeps the file (inferred; prefer archive). |
| No safe deep link into an existing chat | See Hazards. |
| Plan usage is sampled locally, **only while the desktop app is open** | `~/Library/Application Support/Claude/plan-usage-history.json`: `{"version", "samples": [{"t": epoch_ms, "org", "u": {"fh": pct, "sd": pct}}]}`, five-hour / seven-day limits as whole percentages, ~30 days kept. Believed to be every ~5 min in August (**superseded**): on 2026-10-31 the file held 57 samples from 2026-09-30 to 2026-10-30, so gaps of hours to days. |
| The server's rate-limit verdict lands in transcripts | `quotaLimits {status, rateLimitType, resetsAt (epoch s), overageStatus, overageDisabledReason}`. `org_level_disabled` overage ⇒ 100% is a hard stop. |
| `statusLine` is CLI-only | The desktop app ignores it; upstream request anthropics/claude-code#41456. |
| `UNUserNotificationCenter` depends on **where the app lives, not its signature** | 2026-10-31, macOS 26: fresh-bundle-id probes requesting provisional authorization were granted, ad-hoc and Apple Development alike, from `~/Applications`, `~/Desktop`, `~/Downloads` and a repo's `.build` folder (launched with `open` or directly), and refused with `UNErrorDomain Code=1` ("Notifications are not allowed for this application") from `/private/tmp`. The installed Apple Development CacheBar logs `notifications: UNUserNotificationCenter`. Superseded beliefs: "an Apple Development certificate is enough" (August) and "only Developer ID builds" (the morning of 2026-10-31, from probes that happened to live under `/private/tmp`) were both **wrong**. Developer ID itself is untested. |
| `NSUserNotificationCenter` works without authorization | Deprecated, but delivers from an ad-hoc or Apple Development signed bundle with no authorization request, shown as the posting app with its icon; a newer notification with the same `identifier` replaces the one still showing. The app's fallback wherever macOS refuses the native route. |
| `/usr/bin/python3` is a stub without the Command Line Tools | Running it opens the CLT install dialog instead of running anything. `xcode-select -p` fails without CLT and never prompts, so `Pythons.vet` checks it first and never runs the stub. |
| Gatekeeper no longer lets right-click → Open bypass it (macOS 15+) | Un-notarized downloads need **System Settings → Privacy & Security → Open Anyway**, or `xattr -dr com.apple.quarantine`. Release notes say so whenever a build isn't notarized. |

### The plan-limit calibration

**The 2026-08-28 fit (history; the source of the fixed weights).** Fitted against
30 days of `plan-usage-history.json` samples joined to local transcripts
(`message.id`-deduped, subagents included):

```
U = Σ_model w × (input + cache_write_5m + 1.6 × cache_write_1h + 14 × output)
w: fable 2.0 · opus 1.0 · sonnet 0.4 · haiku 0.2
five-hour %  ≈ U / 179 000     seven-day % ≈ U / 1 500 000     (that account, August)
```

- Within a five-hour window, `fh` was linear in U (R² ≈ 1.000); six fully
  sampled windows agreed to ±4.5%; leave-one-out MAE 6.5%.
- **Cache reads weigh 0**: 94% of raw tokens, and the fit degrades monotonically
  as their weight rises (OLS coefficient slightly negative). This single fact
  drives the product: warm chats compacted for ~0.3pp, cold ones for ~2pp.
- fable/opus = 2.0 was recovered **by the fit**, matching the list-price input
  ratio; sonnet/haiku weights rest on <1% of the data.
- Output multiplier and divisor are only jointly identified (14×/179k ≡
  18×/206k); treat the pair as one calibration.
- The seven-day divisor rested on 3 windows disagreeing by 44%: order of
  magnitude only; never alert on it.

**Self-calibration (since 0.1.0).** The weights stay fixed; the divisor differs
per plan tier, so it is refitted on each Mac:

- `_usage_events`: (time, U) per API response from every transcript, subagents
  included, deduped by `message.id`, `<synthetic>` skipped.
- `_plan_windows`: windows chained from local usage. One opens at the first
  response after the previous one closed and ends five hours later, or earlier at
  a sample reading 0 or lower than an earlier one (proof the server's window had
  already reset, e.g. opened from another device). U counts usage up to the
  window's peak sample.
- `_measure_plan`: windows peaking in [5, 100) with U > 0; least squares through
  the origin; needs ≥ 3 windows (`PLAN_MIN_WINDOWS`) and a divisor within
  2,000–5,000,000 (`PLAN_FIT_RANGE`); last 31 days; newest sample's `org` only.
  Keeps aggregates only.
- `plan_calibration`: `source` "env" (`AI_CACHE_5H_PER_PCT`, no fit), "fitted",
  or "default" (179,000). The seven-day divisor is 1,500,000 scaled by the same
  ratio: an assumption that a plan tier scales both limits alike, not a
  measurement.
- `cached_fit`: `~/.claude/.ai-cache-bar-plan.json`, redone daily or on
  `--calibrate`. The app runs `--calibrate` at launch and daily in the background
  (600 s timeout) and sets `AI_CACHE_INLINE_FIT=0` for its polls, which are killed
  after 20 s: a month of transcripts took 6.6–30 s to scan on the author's Mac.
  `--calibrate` prints `{"plan", "plan_fit", "codex"}`.
- `budget`: five-hour figures are null once the newest sample is ≥ 5 h old
  (seven-day: ≥ 7 days), because that window has since reset.
- Check of the method: the fixture's simulated server charges 1% per 120,000
  and the fit recovers 119,302 (7 windows, R² 0.999).

**2026-10-31 findings on real data** (development Mac, `--calibrate`):

- The desktop app samples only while open (57 samples in 30 days, see the facts
  table), so most windows have no sample and can't be used.
- Usage from other devices raises `fh` without local tokens. A reset it causes is
  detected; extra usage inside a window is not, and biases that window.
- This account's fit: **279,989 per 1% from 6 windows, R² 0.956**, against
  179,000 in August (×1.56). Whether the plan, the limits, or the weights'
  validity changed is unknown. 179,000 is only the fallback now; don't present
  it as current.

### Codex

| Fact | Evidence / source |
|---|---|
| A resume spawns a **new rollout file**; all carry the same `session_id` | `~/.codex/sessions/<y>/<m>/<d>/rollout-<ts>-<session_id>[_<sub>].jsonl`, `session_meta` head line. One real session showed as 5 files in 4h; dedupe by id. |
| Chat names live in `~/.codex/session_index.jsonl` | `{"id", "thread_name", "updated_at"}`, last entry wins; covers auto-generated names and user renames. Rollouts never carry a title. |
| Per-call usage | `token_count` events → `payload.info.last_token_usage.{input_tokens, cached_input_tokens, …}`. |
| Eviction curve (that account, 1,019 pairs, 2026-08-28) | ~100% hits ≤10 min idle, ~70% between 10 and ~43 min, none ≥2 h. Matches OpenAI's prompt-caching guidance ("typically cleared after 5–10 minutes of inactivity, always within one hour"). No contractual TTL exists, hence estimate-only display. |
| Self-calibration | `_measure_codex()`: (idle gap → hit?) pairs, prompts ≥5k tokens only; `warm_s` = last gap bucket with hit-share ≥80% (floor 300s), `dead_s` = longest observed survival +60s (at least 2 × `warm_s`, cap 2h), `maybe_pct` = hit-share in between. Cached through `cached_fit()` in `~/.claude/.ai-cache-bar-codex.json`, remeasured on app launch (`--calibrate`) and at most daily otherwise; <100 usable pairs (or no hit or no miss) → defaults 600s/3600s/50%. No `~/.codex/sessions` → no rows and no scan. |

### The cold-tax (rewrite) detector

Signature in a transcript's last two turns: previous turn's cached total >5k, gap
≥ the session's TTL, newest turn's `cache_creation` ≥ `AI_CACHE_REWRITE_MIN` with
`cache_read` < 50% of the previous total, and no compaction in between. Priced as
`w_model × wrote × write_weight(ttl) / per_pct_5h` pp of the five-hour limit
(`write_weight`: 1.6 for the 1h tier, 1.0 for 5m; `per_pct_5h` from the active
calibration). Notify once per event, only while fresh (≤30 min).

## Distribution and signing

- **Local builds** (`packaging/build.sh`): the first Developer ID Application or
  Apple Development identity in the keychain, else ad-hoc (`CODESIGN_IDENTITY`
  overrides; `-` forces ad-hoc). `SHARED=1` (set by `mise run dist`,
  `release.sh --local` and `release.yml`) only accepts a Developer ID or ad-hoc and
  fails on anything else. A Developer ID gets the hardened runtime and a
  timestamp. Version from `VERSION`, else the latest git tag, else `0.0.0-dev`;
  build number = commit count.
- **Releases** are universal and versioned from the tag. `release.yml` signs
  with a Developer ID and notarizes (`notarytool` + `stapler`) when the repo
  secrets exist (`mise run release-secrets`), otherwise ad-hoc, with release notes
  explaining "Open Anyway". `release.sh --local` uses a keychain Developer ID or
  ad-hoc, never Apple Development, and does not notarize. `release.yml` stands
  down when the release already exists (the `--local` path created it).
- Native notifications don't depend on the signature (see the facts table);
  where macOS refuses them the app uses the `NSUserNotificationCenter` fallback.
  Notification authorization is cached per bundle id (`CACHEBAR_BUNDLE_ID` for a
  fresh one).
- `release.sh` refuses a dirty tree, a branch other than `main`, an existing tag,
  or a `main` that differs from the GitHub remote's, and runs the build, script
  tests and e2e tests before tagging. The scripts pick the remote whose URL
  contains github.com, whatever its name (`REMOTE=` overrides).
