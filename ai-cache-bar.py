#!/usr/bin/python3
"""ai-cache-bar — prompt-cache warmth across the AI coding tools on this Mac.

Surfaces:
  --swiftbar   SwiftBar/xbar menu bar plugin output (title line + dropdown)
  --notify     macOS notification on warm -> expiring -> cold transitions
  --text       one-line-per-session summary for a terminal
  --json       machine-readable (what CacheBar.app consumes)
  --calibrate  remeasure the plan-budget and codex calibrations now (CacheBar.app
               runs this once per launch; otherwise both refresh at most daily)

Providers, using only data these tools already write locally:
  claude  ~/.claude/projects/**/*.jsonl  — the cache TTL is chosen per request, so
          each session's tier is read from its own newest turn that wrote cache
          (cache_creation.ephemeral_1h_input_tokens -> 1h, ephemeral_5m -> 5 min;
          3600 when unknown). Each turn refreshes the TTL, so deadline = last turn
          + TTL. Exact countdown.
  codex   ~/.codex/sessions/**/*.jsonl   — last_token_usage.cached_input_tokens per
          turn, one row per session_id (a resume spawns a new rollout file, so files
          must be deduped). OpenAI implicit caching has no contractual TTL, so the
          countdown is an estimate (codex_calibration(), measured locally) shown
          with a ~.

Chat titles come from the transcript's own "custom-title" / "ai-title" entries
(a custom title wins), cached in .ai-cache-bar-titles.json so a full-file scan
happens at most once per session.

No deep link can focus an already-open desktop-app chat (README.md documents the
two claude:// routes that were tried and why each is wrong — one destructively),
so nothing is clickable: rows and notifications are information only. Rows still
carry the transcript path, for reference. The git-worktrees.json mapping is kept
to collapse a resumed chat's transcripts into one row.

Warning threshold defaults to 10 minutes before a one-hour cache expires
(AI_CACHE_WARN_SECONDS changes it); a shorter tier gets the same share of its
TTL, 50 seconds for a 5-minute chat.

Plan budget: plan-usage-history.json gives the five-hour and seven-day limits as
percentages, and budget() estimates what compacting every open chat would cost
against them — see the calibration note above DEFAULT_5H_PER_PCT. The divisor
that turns weighted tokens into percent is fitted from this Mac's own history
(plan_calibration()), since every plan tier has a different one. Warm chats are
nearly free to compact (their context re-reads from cache, which does not count);
cold ones are not.

AI_CACHE_NOW (epoch seconds) pins the clock — every age, countdown, lookback and
calibration-freshness check reads clock() — for golden tests and demo data.

Stdlib only (no jq, no mise), Python 3.6+, so any python3 works and the
/usr/bin/python3 shebang runs under SwiftBar's and launchd's minimal PATH. The app
doesn't rely on the shebang: it finds a working python3 itself.
"""
import bisect
import calendar
import glob
import json
import math
import os
import subprocess
import sys
import time


def _env_int(name):
    """An integer knob, or None when it isn't set (so "set explicitly" is visible)."""
    value = os.environ.get(name)
    return int(value) if value else None


# Claude's TTL is per request, so each session's is read from its own transcript
# (cache_ttl()); AI_CACHE_TTL_SECONDS forces one value on every session.
TTL_OVERRIDE = _env_int("AI_CACHE_TTL_SECONDS")
DEFAULT_TTL = 3600
WARN_OVERRIDE = _env_int("AI_CACHE_WARN_SECONDS")
WARN = 600
LOOKBACK = int(os.environ.get("AI_CACHE_LOOKBACK_MIN", "240")) * 60
TAIL_BYTES = int(os.environ.get("AI_CACHE_TAIL_BYTES", str(256 * 1024)))
MAX_ROWS = int(os.environ.get("AI_CACHE_MAX_ROWS", "10"))
NOTIFY_MAX_AGE = int(os.environ.get("AI_CACHE_NOTIFY_MAX_AGE", "7200"))
# A stale calibration is remeasured inline by whichever run finds it stale.
# CacheBar.app sets this to 0 for its polls and runs --calibrate itself, daily and
# with room to finish, so a long scan never lands in a poll it kills after 20 s.
INLINE_FIT = os.environ.get("AI_CACHE_INLINE_FIT", "1") != "0"

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
STATE = os.path.join(HOME, ".claude", ".ai-cache-bar-state.json")
TITLE_CACHE = os.path.join(HOME, ".claude", ".ai-cache-bar-titles.json")
CODEX_CAL = os.path.join(HOME, ".claude", ".ai-cache-bar-codex.json")
PLAN_CAL = os.path.join(HOME, ".claude", ".ai-cache-bar-plan.json")
CODEX_SESSIONS = os.path.join(HOME, ".codex", "sessions")
WORKTREES = os.path.join(HOME, "Library", "Application Support", "Claude",
                        "git-worktrees.json")


# ---------------------------------------------------------------- file helpers

def clock():
    """Epoch seconds now — or AI_CACHE_NOW, which pins it for tests and demo data.

    Everything time-relative takes its `now` from here, never time.time().
    """
    pinned = os.environ.get("AI_CACHE_NOW")
    return float(pinned) if pinned else time.time()


def tail_lines(path, nbytes=TAIL_BYTES):
    """Last lines of a file without reading the whole thing (transcripts get big)."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            start = max(0, fh.tell() - nbytes)
            fh.seek(start)
            data = fh.read()
    except OSError:
        return []
    if start:  # first line is probably partial
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
    return data.splitlines()


def epoch(ts):
    """'2026-08-27T08:26:53.253Z' -> unix seconds (transcripts are always UTC)."""
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return None


def load_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (IOError, OSError, ValueError):
        return default


def save_json(path, obj):
    """Write via a temp file and rename, so a concurrent poll never reads half a
    file. False when it can't be written (no ~/.claude, read-only, ...)."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w") as fh:
            json.dump(obj, fh)
        os.replace(tmp, path)
        return True
    except (IOError, OSError):
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def _fresh(stamp, now, span):
    """stamp lies within the last `span` seconds (a future stamp — the clock was
    pinned earlier than the cache — counts as stale)."""
    return isinstance(stamp, (int, float)) and 0 <= now - stamp < span


def cached_fit(path, measure, now, force=False):
    """A calibration cached at `path`, remeasured on force (--calibrate, which
    CacheBar.app fires once per launch) or when older than a day.

    Returns None — the caller then uses its defaults — when the cache can't be
    written: without it every 15 s poll would rescan the whole history. A claim
    written before measuring keeps concurrent polls from scanning too; they make
    do with the stale fit (or the defaults) for those few seconds.
    """
    cal = load_json(path, None)
    if not isinstance(cal, dict):
        cal = None
    if cal and not force:
        if _fresh(cal.get("computed_at"), now, 86400):
            return cal
        if _fresh(cal.get("claimed_at"), now, 600):
            return cal if "computed_at" in cal else None
    if not force and not INLINE_FIT:
        return cal if cal and "computed_at" in cal else None
    if not save_json(path, dict(cal or {}, claimed_at=int(now))):
        return None
    fit = measure()
    fit["computed_at"] = int(now)
    save_json(path, fit)
    return fit


def recent_files(pattern, now, skip=None, within=LOOKBACK):
    for path in glob.iglob(pattern, recursive=True):
        if skip and skip in path:
            continue
        try:
            if now - os.stat(path).st_mtime <= within:
                yield path
        except OSError:
            continue


def claude_transcripts(now):
    """Main-chain transcripts touched within the lookback. Globbed once per poll and
    shared by the session rows and the quota check; sorted so that ties resolve the
    same way on every run."""
    # Subagents keep their own cache prefix in <session>/subagents/; they are not
    # the session you are typing into, so they stay out of the menu bar.
    return sorted(recent_files(os.path.join(PROJECTS, "**", "*.jsonl"), now,
                               skip="/subagents/"))


# ------------------------------------------------------------------ chat title

def _titles_from(lines):
    """(custom, ai) titles found in an iterable of raw jsonl lines."""
    custom = ai = None
    for line in lines:
        if b"-title" not in line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "custom-title" and e.get("customTitle"):
            custom = e["customTitle"]
        elif e.get("type") == "ai-title" and e.get("aiTitle"):
            ai = e["aiTitle"]
    return custom, ai


def session_title(path, sid, tail, cache):
    """Title for a session, preferring a user-set custom title over the AI one."""
    custom, ai = _titles_from(tail)
    title = custom or ai
    if title:
        cache[sid] = title
        return title
    if sid in cache:
        return cache[sid]
    # Titles are written early in a long transcript, so fall back to a full scan —
    # once, then cached.
    try:
        with open(path, "rb") as fh:
            custom, ai = _titles_from(fh)
    except OSError:
        return None
    title = custom or ai
    if title:
        cache[sid] = title
    return title


# ---------------------------------------------------- desktop-app session mapping

def worktree_owners():
    """realpath of a worktree -> the app session (local_<uuid>) leasing it."""
    raw = load_json(WORKTREES, None)
    if raw is None:
        return {}
    trees = None
    if isinstance(raw, dict):
        trees = raw.get("worktrees")
    elif isinstance(raw, list):  # serialized Map: [{key, value}, ...]
        for item in raw:
            if isinstance(item, dict) and item.get("key") == "worktrees":
                trees = item.get("value")
                break
    if not isinstance(trees, dict):
        return {}
    out = {}
    for wt in trees.values():
        if not isinstance(wt, dict):
            continue
        path, owner = wt.get("path"), wt.get("leasedBy")
        if path and owner:
            out[os.path.realpath(path)] = owner
    return out


def app_session_for(cwd, owners):
    """Longest-prefix match, so a subdirectory of a worktree still resolves."""
    if not cwd or not owners:
        return None
    try:
        real = os.path.realpath(cwd)
    except OSError:
        return None
    best = None
    for path, owner in owners.items():
        if real == path or real.startswith(path + os.sep):
            if best is None or len(path) > len(best[0]):
                best = (path, owner)
    return best[1] if best else None


# ------------------------------------------------------------- plan budget

PLAN_USAGE = os.path.join(HOME, "Library", "Application Support", "Claude",
                          "plan-usage-history.json")

# plan-usage-history.json holds ~5-minute samples of {"fh": pct, "sd": pct} — the
# five-hour and seven-day plan limits as whole percentages.
#
# Turning a token estimate into a percentage needed a calibration, done against 30
# days of those samples (2026-08-28). Within a five-hour window fh is linear in
# cost-weighted tokens (R^2 1.000) and six fully-sampled windows agree to +/-4.5%.
# The weighting that fits:
#
#   U = sum over models of  w * (input + cache_write_5m + 1.6*cache_write_1h
#                                + 14*output)
#
# Cache READS carry weight 0 — they are 94% of raw tokens here and the fit degrades
# monotonically as their weight rises (a 4-term OLS even puts them slightly
# negative). That is the whole reason a warm chat is cheap to compact and a cold one
# is not. The output multiplier is only jointly identified with the divisor
# (14/179k and 18/206k fit equally well), so treat the pair as one calibration.
#
# The weights stay fixed; the divisor is what differs per plan tier, so
# _measure_plan() refits it from this Mac's own history and the constants below
# are only the fallback (that original account's fit).
#
# The seven-day figure rests on 3 windows that disagree by 44% — order of
# magnitude only, quite possibly not even linear if sd is a max over sub-meters.
# It is never fitted; plan_calibration() scales it by the five-hour ratio.
DEFAULT_5H_PER_PCT = 179000
DEFAULT_7D_PER_PCT = 1500000
OUTPUT_WEIGHT = 14
CACHE_1H_WEIGHT = 1.6
# Observed fable/opus ratio recovered independently by the fit as exactly 2.0, which
# is the list-price input ratio. sonnet/haiku rest on <1% of the data.
MODEL_WEIGHTS = (("fable", 2.0), ("opus", 1.0), ("sonnet", 0.4), ("haiku", 0.2))
# A compaction emits one summary; output is the expensive term at 14x.
COMPACT_SUMMARY_OUT = int(os.environ.get("AI_CACHE_COMPACT_OUT", "4000"))
# Smallest prefix rewrite worth a "you just paid the cold tax" notification.
REWRITE_MIN = int(os.environ.get("AI_CACHE_REWRITE_MIN", "25000"))

FIVE_HOURS = 5 * 3600
# How far back the self-calibration reads. The app keeps ~30 days of samples,
# pruned relative to its own last write, so one day of slack covers the oldest.
PLAN_CAL_DAYS = 31
# A window that peaked below 5% is mostly integer rounding (+/-10% at 5); one at
# 100% is censored (the cap stopped it, so its fh understates its U).
PLAN_MIN_PEAK = 5
# Fewest usable windows before the fit replaces the default. Low on purpose: it is
# a one-parameter fit, and the default is one account's divisor — off by the
# plan-tier ratio (5-20x) for anyone on another tier.
PLAN_MIN_WINDOWS = 3
# Sanity range for a fitted divisor (default 179000); outside it the history is
# measuring something else, e.g. a limit spent on claude.ai rather than here.
PLAN_FIT_RANGE = (2000, 5000000)


def model_weight(model):
    name = (model or "").lower()
    for key, w in MODEL_WEIGHTS:
        if key in name:
            return w
    return 1.0


def write_weight(ttl):
    """Plan weight of a cache write: the 1h tier costs 1.6x the 5-minute one
    (2x vs 1.25x base input, the same ratio the calibration recovered)."""
    return 1.0 if ttl <= 300 else CACHE_1H_WEIGHT


def weighted_tokens(usage, model):
    """U for one API response — the calibrated weighting above."""
    cc = usage.get("cache_creation")
    cc = cc if isinstance(cc, dict) else {}
    w5 = cc.get("ephemeral_5m_input_tokens")
    w1 = cc.get("ephemeral_1h_input_tokens")
    if w5 is None and w1 is None:
        # no tier split recorded: count it at the API's default 5-minute tier
        w5, w1 = usage.get("cache_creation_input_tokens") or 0, 0
    return model_weight(model) * ((usage.get("input_tokens") or 0) + (w5 or 0)
                                  + CACHE_1H_WEIGHT * (w1 or 0)
                                  + OUTPUT_WEIGHT * (usage.get("output_tokens") or 0))


def _plan_samples(now):
    """(epoch, usage dict) samples up to now, oldest first, for the account of the
    newest sample (each sample carries an "org"; someone switching accounts
    would otherwise mix two plans' limits)."""
    raw = load_json(PLAN_USAGE, None)
    samples = raw.get("samples") if isinstance(raw, dict) else None
    if not isinstance(samples, list):
        return []
    out = []
    for s in samples:
        if not isinstance(s, dict) or not isinstance(s.get("u"), dict):
            continue
        t = s.get("t")
        if isinstance(t, (int, float)) and t / 1000.0 <= now:
            out.append((t / 1000.0, s.get("org"), s["u"]))
    out.sort(key=lambda x: x[0])
    org = out[-1][1] if out else None
    return [(t, u) for t, o, u in out if o == org]


def plan_usage(now):
    """Newest {"fh", "sd"} sample, or None when the app has never sampled."""
    for at, u in reversed(_plan_samples(now)):
        if "fh" in u or "sd" in u:
            return {"fh": u.get("fh"), "sd": u.get("sd"), "at": at}
    return None


def _usage_events(since, now):
    """(epoch, U) per API response since `since`, from every transcript including
    subagents (their own cache prefix, but ~1/3 of real spend).

    One response is written as one line per content block, each repeating its
    usage, so entries are deduped by message.id (the last line wins: streaming
    partials come first). Only aggregates leave this function.
    """
    seen = {}
    pat = os.path.join(PROJECTS, "**", "*.jsonl")
    for path in recent_files(pat, now, within=now - since):
        try:
            with open(path, "rb") as fh:
                for line in fh:
                    if b'"usage"' not in line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    msg = e.get("message") if isinstance(e, dict) else None
                    if not isinstance(msg, dict):
                        continue
                    usage, mid = msg.get("usage"), msg.get("id")
                    if not (isinstance(usage, dict) and mid) \
                            or msg.get("model") == "<synthetic>":
                        continue
                    at = epoch(e.get("timestamp", ""))
                    if at is not None and since <= at <= now:
                        seen[mid] = (at, weighted_tokens(usage, msg.get("model")))
        except OSError:
            continue
    return sorted(seen.values())


def _plan_windows(events, samples):
    """(U at the window's peak sample, peak fh) per five-hour window.

    The server opens a window at the first message after the previous one closed
    and resets it five hours later, so windows are chained from local usage. A
    sample that reads 0, or lower than an earlier one in the same window, proves
    the server's window had already reset (it was opened earlier, e.g. from
    another device): the local window ends there and the next one starts at the
    first response after that sample. U counts usage up to the peak sample only.
    """
    times = [t for t, _ in samples]
    out = []
    i = 0
    while i < len(events):
        start = events[i][0]
        end = start + FIVE_HOURS
        peak = at = None
        for t, fh in samples[bisect.bisect_left(times, start):]:
            if t >= end:
                break
            if (fh == 0 and t > start) or (peak is not None and fh < peak):
                end = t
                break
            if peak is None or fh > peak:
                peak, at = fh, t  # first sample to reach the peak
        # First response at/after end; always past i, or a reset sample at the
        # window's very first second would loop here forever.
        j = max(bisect.bisect_left(events, (end,), i), i + 1)
        if peak is not None:
            out.append((sum(u for t, u in events[i:j] if t <= at), peak))
        i = j
    return out


def _measure_plan(now):
    """Fit the five-hour divisor from this Mac's own history: least squares
    through the origin of each window's U against its peak fh, with the weights
    above held fixed. per_pct_5h is None when fewer than PLAN_MIN_WINDOWS windows
    are usable. Aggregates only — no transcript content, title or path is kept.
    """
    started = time.time()
    samples = [(t, u["fh"]) for t, u in _plan_samples(now)
               if isinstance(u.get("fh"), (int, float))
               and t >= now - PLAN_CAL_DAYS * 86400]
    pts = []
    if samples:
        # A window holding the oldest sample opened at most five hours before it.
        events = _usage_events(samples[0][0] - FIVE_HOURS, now)
        pts = [(u, p) for u, p in _plan_windows(events, samples)
               if PLAN_MIN_PEAK <= p < 100 and u > 0]
    fit = {"per_pct_5h": None, "windows": len(pts), "r2": None}
    if len(pts) >= PLAN_MIN_WINDOWS:
        d = sum(u * p for u, p in pts) / float(sum(p * p for u, p in pts))
        mean = sum(u for u, _ in pts) / float(len(pts))
        sst = sum((u - mean) ** 2 for u, _ in pts)
        if sst:
            fit["r2"] = round(1 - sum((u - d * p) ** 2 for u, p in pts) / sst, 3)
        if PLAN_FIT_RANGE[0] <= d <= PLAN_FIT_RANGE[1]:
            fit["per_pct_5h"] = int(round(d))
        else:
            fit["rejected"] = int(round(d))
    fit["scan_seconds"] = round(time.time() - started, 1)
    return fit


def plan_calibration(now, force=False):
    """Divisors that turn weighted tokens into percent of each plan limit.

    source "env": AI_CACHE_5H_PER_PCT, which skips the fit entirely; "fitted":
    _measure_plan() on this Mac's history, cached like the codex curve; "default":
    too little history (or no writable cache), so the original account's
    constants. The seven-day divisor is scaled by the same ratio as the five-hour
    one — an assumption (that a plan tier scales both limits alike), not a
    measurement — unless AI_CACHE_7D_PER_PCT sets it.
    """
    env5 = _env_int("AI_CACHE_5H_PER_PCT")
    fit = {}
    if env5 is None or force:
        fit = cached_fit(PLAN_CAL, lambda: _measure_plan(now), now, force) or {}
    if env5 is not None:
        cal = {"source": "env", "windows": 0, "per_pct_5h": env5}
    elif fit.get("per_pct_5h"):
        cal = {"source": "fitted", "windows": fit["windows"],
               "per_pct_5h": fit["per_pct_5h"]}
    else:
        cal = {"source": "default", "windows": fit.get("windows", 0),
               "per_pct_5h": DEFAULT_5H_PER_PCT}
    env7 = _env_int("AI_CACHE_7D_PER_PCT")
    cal["per_pct_7d"] = env7 if env7 is not None else int(round(
        DEFAULT_7D_PER_PCT * cal["per_pct_5h"] / float(DEFAULT_5H_PER_PCT)))
    return cal


def quota_reset(now, paths):
    """Reset time of a limit that is currently being enforced, if any.

    Claude Code writes the server's rate-limit verdict into the transcript as
    quotaLimits {status, rateLimitType, resetsAt}. A resetsAt in the past is just
    an old rejection, so only a future one is reported.
    """
    best = None
    for path in paths:
        for line in reversed(tail_lines(path, 64 * 1024)):
            if b"quotaLimits" not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            q = _find_quota(e)
            if not q:
                continue
            at = q.get("resetsAt")
            if not isinstance(at, (int, float)) or at <= now:
                continue
            if best is None or at > best["resets_at"]:
                best = {"resets_at": int(at),
                        "resets_in": int(at - now),
                        "kind": q.get("rateLimitType"),
                        "status": q.get("status"),
                        "overage": q.get("overageStatus")}
            break
    return best


def _find_quota(node):
    if isinstance(node, dict):
        if "resetsAt" in node and "rateLimitType" in node:
            return node
        for v in node.values():
            got = _find_quota(v)
            if got:
                return got
    elif isinstance(node, list):
        for v in node:
            got = _find_quota(v)
            if got:
                return got
    return None


def compaction_cost(row):
    """Weighted tokens one compaction of this chat would spend.

    A warm chat's context re-enters the request as a cache read, which does not
    count against the plan at all, so only the summary output costs anything. A cold
    chat has to have its whole context rewritten first, at its own cache tier.
    """
    ctx = row.get("context") or 0
    rewrite = (0 if row["state"] in ("warm", "expiring")
               else ctx * write_weight(row.get("ttl", DEFAULT_TTL)))
    return model_weight(row["model"]) * (rewrite + COMPACT_SUMMARY_OUT * OUTPUT_WEIGHT)


def pct_int(x):
    """Whole percent, rounding half up (not Python's half-to-even), so a port
    reproduces it exactly."""
    return int(math.floor(x + 0.5))


def budget(rows, now, paths, cal):
    """What compacting every open chat would cost against the plan limits."""
    chats = [r for r in rows if r["tool"] == "claude"]
    total = sum(compaction_cost(r) for r in chats)
    cold = [r for r in chats if r["state"] == "cold"]
    per_5h, per_7d = float(cal["per_pct_5h"]), float(cal["per_pct_7d"])
    usage = plan_usage(now)
    out = {
        "chats": len(chats),
        "cold_chats": len(cold),
        "compaction_tokens": int(total),
        "compaction_pct_5h": round(total / per_5h, 1),
        "compaction_pct_7d": round(total / per_7d, 1),
        "cold_share_pct_5h": round(sum(compaction_cost(r) for r in cold) / per_5h, 1),
        "used_pct_5h": None,
        "used_pct_7d": None,
        "left_pct_5h": None,
        "left_pct_7d": None,
        "usage_sample_age": None,
        "would_exhaust_5h": False,
        "would_exhaust_7d": False,
        "reset": quota_reset(now, paths),
        "calibration": {"source": cal["source"], "windows": cal["windows"],
                        "per_pct_5h": cal["per_pct_5h"]},
    }
    if usage:
        age = int(now - usage["at"])
        out["usage_sample_age"] = age
        # A sample older than its limit's window describes a window that has
        # since reset: what is used now is unknown, not what it said then.
        if isinstance(usage.get("fh"), (int, float)) and age < FIVE_HOURS:
            out["used_pct_5h"] = pct_int(usage["fh"])
            out["left_pct_5h"] = max(0, 100 - out["used_pct_5h"])
            out["would_exhaust_5h"] = out["compaction_pct_5h"] >= out["left_pct_5h"]
        if isinstance(usage.get("sd"), (int, float)) and age < 7 * 86400:
            out["used_pct_7d"] = pct_int(usage["sd"])
            out["left_pct_7d"] = max(0, 100 - out["used_pct_7d"])
            out["would_exhaust_7d"] = out["compaction_pct_7d"] >= out["left_pct_7d"]
    return out


# ------------------------------------------------------------------- providers

def cache_ttl(usage):
    """TTL tier a turn wrote its cache at, from the cache_creation split; None when
    it wrote nothing or predates the split.

    Claude Code mostly writes the 1h tier but switches some sessions to the 5-minute
    one mid-chat (subagents always use it), so the newest write is what counts.
    Both tiers in one turn was never observed; the larger write would govern.
    """
    cc = usage.get("cache_creation")
    if not isinstance(cc, dict):
        return None
    w5 = cc.get("ephemeral_5m_input_tokens") or 0
    w1 = cc.get("ephemeral_1h_input_tokens") or 0
    if not (w5 or w1):
        return None
    return 300 if w5 > w1 else 3600


def warn_for(ttl):
    """Lead time of the "expiring" state. The base (AI_CACHE_WARN_SECONDS, else 10
    minutes) is meant for a one-hour cache; a shorter tier gets the same share of
    its TTL, so a 5-minute chat isn't expiring from its first second. With the TTL
    pinned by AI_CACHE_TTL_SECONDS (the test trick) an explicit base applies as is."""
    if TTL_OVERRIDE is not None:
        return WARN_OVERRIDE if WARN_OVERRIDE is not None else min(WARN, ttl // 6)
    base = WARN_OVERRIDE if WARN_OVERRIDE is not None else WARN
    return base * min(ttl, 3600) // 3600


def claude_sessions(now, titles, paths, per_pct_5h):
    out = {}
    owners = worktree_owners()
    for path in paths:
        tail = tail_lines(path)
        last = prev = compact_at = ttl = None
        for line in reversed(tail):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            # A compaction replaces the whole prefix but writes no usage of its
            # own, so the newest one has to be tracked separately. Reversed scan,
            # so the first hit is the newest.
            if e.get("isCompactSummary") and compact_at is None:
                compact_at = epoch(e.get("timestamp", ""))
            msg = e.get("message") or {}
            usage = msg.get("usage")
            if not (usage and e.get("requestId") and not e.get("isSidechain")):
                continue
            # "<synthetic>" entries (compaction stubs, API-error notices such as a
            # rate-limit rejection) carry all-zero usage: no turn happened.
            if msg.get("model") == "<synthetic>":
                continue
            if ttl is None:
                ttl = cache_ttl(usage)
            if last is None:
                last = (e, usage)
            elif prev is None and e["requestId"] != last[0]["requestId"]:
                # reversed scan, so this is the final entry of the turn before
                prev = (e, usage)
            if prev is not None and ttl is not None:
                break
        if not last:
            continue
        if TTL_OVERRIDE is not None:
            ttl = TTL_OVERRIDE
        elif ttl is None:
            ttl = DEFAULT_TTL
        e, usage = last
        at = epoch(e.get("timestamp", ""))
        if at is None:
            continue
        sid = e.get("sessionId") or path
        cwd = e.get("cwd") or ""
        branch = e.get("gitBranch") or ""
        model = (e.get("message") or {}).get("model") or "?"
        app_session = app_session_for(cwd, owners)
        # The cold-tax signature: the previous turn held a real cached prefix, the
        # gap outlived the TTL, and this turn rewrote instead of reading.
        rewrote = rewrite_at = rewrite_gap = rewrite_pct = None
        if prev:
            p_at = epoch(prev[0].get("timestamp", ""))
            p_tot = (prev[1].get("cache_read_input_tokens") or 0) + (
                prev[1].get("cache_creation_input_tokens") or 0)
            wrote = usage.get("cache_creation_input_tokens") or 0
            read = usage.get("cache_read_input_tokens") or 0
            # A compaction between the two turns rewrites the prefix by design;
            # that is not the cold tax, so it must not be reported as one.
            by_compaction = (compact_at is not None and p_at is not None
                             and compact_at > p_at)
            if (p_at is not None and not by_compaction
                    and p_tot > 5000 and wrote >= REWRITE_MIN
                    and read < p_tot * 0.5 and at - p_at >= ttl):
                rewrote, rewrite_at, rewrite_gap = wrote, int(at), int(at - p_at)
                rewrite_pct = round(model_weight(model) * wrote * write_weight(ttl)
                                    / per_pct_5h, 1)
        row = {
            "tool": "claude",
            "session": sid,
            "title": session_title(path, sid, tail, titles),
            "label": (os.path.basename(cwd) or "?") + (("@" + branch) if branch else ""),
            "model": model,
            "cwd": cwd,
            "age": int(now - at),
            "left": int(ttl - (now - at)),
            "ttl": ttl,
            "cached": (usage.get("cache_read_input_tokens") or 0)
            + (usage.get("cache_creation_input_tokens") or 0),
            # everything a compaction would have to re-send
            "context": (usage.get("input_tokens") or 0)
            + (usage.get("cache_read_input_tokens") or 0)
            + (usage.get("cache_creation_input_tokens") or 0),
            "ttl_known": True,
            "ttl_estimate": False,
            "rewrote": rewrote,
            "rewrite_at": rewrite_at,
            "rewrite_age": (int(now - rewrite_at) if rewrite_at else None),
            "rewrite_gap": rewrite_gap,
            "rewrite_pct_5h": rewrite_pct,
            "app_session": app_session,
            "path": path,
        }
        if compact_at is not None and compact_at > at:
            # Compacted since the last turn: the old prefix is gone from the
            # conversation (so reporting its size and TTL is doubly wrong) and
            # the summary that replaced it is not cached until the next turn.
            row.update({
                "state": "compacted",
                "age": int(now - compact_at),
                "left": 0,
                "cached": 0,
                "context": 0,
                "ttl_known": False,
                "compacted_at": int(compact_at),
            })
        if sid not in out or out[sid]["age"] > row["age"]:
            out[sid] = row
    return list(out.values())


CODEX_DEFAULT = {"warm_s": 600, "dead_s": 3600, "maybe_pct": 50, "pairs": 0,
                 "default": True}


def _measure_codex():
    """Fit the codex eviction curve from this account's own rollout history.

    OpenAI implicit caching has no contractual TTL, but every rollout records
    (idle gap before a call, whether that call still hit the cache). From those
    pairs: warm_s = the largest idle gap the cache reliably survives (bucketed
    hit-share stays >= 80%), dead_s = the longest survival ever observed, and
    maybe_pct = the hit-share in the zone between them. Returns None when the
    history is too thin to say anything.
    """
    sessions = {}
    for f in glob.iglob(os.path.join(CODEX_SESSIONS, "**", "*.jsonl"), recursive=True):
        sid = None
        try:
            with open(f, "rb") as fh:
                for line in fh:
                    if b"token_count" not in line and b"session_meta" not in line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if e.get("type") == "session_meta":
                        meta = e.get("payload") or {}
                        sid = meta.get("session_id") or meta.get("id")
                        continue
                    payload = e.get("payload") or {}
                    if payload.get("type") != "token_count":
                        continue
                    usage = (payload.get("info") or {}).get("last_token_usage")
                    at = epoch(e.get("timestamp", ""))
                    if not usage or at is None:
                        continue
                    sessions.setdefault(sid or f, []).append(
                        (at, usage.get("input_tokens") or 0,
                         usage.get("cached_input_tokens") or 0))
        except OSError:
            continue
    pairs = []
    for turns in sessions.values():
        turns.sort()
        for i in range(1, len(turns)):
            at, inp, cached = turns[i]
            gap = at - turns[i - 1][0]
            if inp >= 5000 and gap >= 1:  # too small a prompt proves nothing
                pairs.append((gap, cached / float(inp)))
    hits = [g for g, h in pairs if h > 0.5]
    misses = [g for g, h in pairs if h <= 0.5]
    if len(pairs) < 100 or not hits or not misses:
        return None
    edges = [0, 60, 120, 300, 600, 900, 1800, 3600, 7200]
    warm = 300  # never claim reliability below what OpenAI documents as typical
    for lo, hi in zip(edges, edges[1:]):
        bucket = [h for g, h in pairs if lo <= g < hi]
        if len(bucket) < 3:
            continue  # no evidence either way — keep extending
        if sum(1 for h in bucket if h > 0.5) / float(len(bucket)) < 0.8:
            break
        warm = max(warm, hi)
    dead = min(max(int(max(hits)) + 60, warm * 2), 7200)
    mid = [h for g, h in pairs if warm <= g < dead]
    maybe = (int(round(100.0 * sum(1 for h in mid if h > 0.5) / len(mid)))
             if mid else 50)
    return {"warm_s": warm, "dead_s": dead, "maybe_pct": maybe,
            "pairs": len(pairs)}


def codex_calibration(now, force=False):
    """Cached eviction-curve fit; remeasured at most daily (or on --calibrate,
    which CacheBar.app fires once per launch). Defaults when it can't be cached."""
    cal = cached_fit(CODEX_CAL, lambda: _measure_codex() or dict(CODEX_DEFAULT),
                     now, force) or dict(CODEX_DEFAULT)
    env = os.environ.get("AI_CACHE_CODEX_TTL_SECONDS")
    if env:
        cal = dict(cal, warm_s=int(env))
    return cal


def codex_titles():
    """id -> thread_name from ~/.codex/session_index.jsonl (last entry wins).

    This is where Codex keeps chat names — both its auto-generated ones and
    user renames; the rollout files themselves never carry a title."""
    out = {}
    try:
        with open(os.path.join(HOME, ".codex", "session_index.jsonl"), "rb") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("id") and e.get("thread_name"):
                    out[e["id"]] = e["thread_name"]
    except OSError:
        pass
    return out


def _codex_meta(path):
    """session_meta from a rollout file's first line ({} when absent)."""
    try:
        with open(path, "rb") as fh:
            e = json.loads(fh.readline())
    except (OSError, ValueError):
        return {}
    if e.get("type") != "session_meta":
        return {}
    return e.get("payload") or {}


def codex_sessions(now):
    # Codex starts a NEW rollout file on every resume, all carrying the same
    # session_id in their session_meta head line — so dedupe by that id or one
    # chat shows up once per resume. Titles live in session_index.jsonl, not in
    # the rollouts; the cwd-based label is the fallback for unnamed chats.
    if not os.path.isdir(CODEX_SESSIONS):
        return []  # no codex here: no titles, no calibration scan, no glob
    out = {}
    titles = codex_titles()
    cal = codex_calibration(now)
    pat = os.path.join(CODEX_SESSIONS, "**", "*.jsonl")
    for path in sorted(recent_files(pat, now)):
        for line in reversed(tail_lines(path)):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            payload = e.get("payload") or {}
            if payload.get("type") != "token_count":
                continue
            usage = (payload.get("info") or {}).get("last_token_usage")
            if not usage:
                continue
            at = epoch(e.get("timestamp", ""))
            if at is None:
                break
            meta = _codex_meta(path)
            sid = meta.get("session_id") or meta.get("id") or os.path.basename(path)
            cwd = meta.get("cwd") or ""
            git = meta.get("git") if isinstance(meta.get("git"), dict) else {}
            branch = git.get("branch") or ""
            inp = usage.get("input_tokens") or 0
            cached = usage.get("cached_input_tokens") or 0
            age = int(now - at)
            # Nothing past warm_s is knowable, only likely — hence the traffic
            # light instead of claude's deterministic warm/cold.
            if age < cal["warm_s"]:
                state = "est_warm"
            elif age < cal["dead_s"]:
                state = "uncertain"
            else:
                state = "est_gone"
            row = {
                "tool": "codex",
                "session": sid,
                "title": titles.get(sid),
                "label": "codex " + (os.path.basename(cwd) or "?")
                + (("@" + branch) if branch else ""),
                "model": "codex",
                "cwd": cwd,
                "age": age,
                "left": int(cal["warm_s"] - age),
                "state": state,
                "maybe_pct": cal["maybe_pct"],
                "cached": cached,
                "context": inp,
                "hit_rate": (int(round(100.0 * cached / inp)) if inp else 0),
                "ttl_known": True,
                "ttl_estimate": True,
                "app_session": None,
                "path": path,
            }
            if sid not in out or out[sid]["age"] > row["age"]:
                out[sid] = row
            break
    return list(out.values())


def collect(now, paths, cal):
    titles = load_json(TITLE_CACHE, {})
    before = dict(titles)
    rows = claude_sessions(now, titles, paths, cal["per_pct_5h"]) + codex_sessions(now)
    # A worktree lease points at one chat, so several transcripts resolving to the
    # same app session are the same chat resumed; only the freshest is live.
    by_app = {}
    for r in rows:
        key = r.get("app_session")
        if not key:
            continue
        if key not in by_app or by_app[key]["age"] > r["age"]:
            by_app[key] = r
    rows = [r for r in rows
            if not r.get("app_session") or by_app[r["app_session"]] is r]
    for r in rows:
        if "state" not in r:
            if not r["ttl_known"]:
                r["state"] = "untracked"
            elif r["left"] <= 0:
                r["state"] = "cold"
            elif r["left"] < warn_for(r.get("ttl", DEFAULT_TTL)):
                r["state"] = "expiring"
            else:
                r["state"] = "warm"
        r["display"] = r.get("title") or r["label"]
    # live sessions first, most urgent at the top; then the cold ones by recency
    rows.sort(key=lambda r: (0, r["left"])
              if r["state"] in ("warm", "expiring", "est_warm", "compacted")
              else (1, r["age"]))
    if titles != before:
        save_json(TITLE_CACHE, titles)
    return rows


# --------------------------------------------------------------------- render

def hms(seconds):
    s = abs(int(seconds))
    if s >= 3600:
        return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
    if s >= 60:
        return "%dm" % (s // 60)
    return "%ds" % s


def kt(n):
    return ("%dk" % (n // 1000)) if n >= 1000 else str(n)


ICON = {"warm": "🔥", "expiring": "⚠️", "cold": "❄️", "untracked": "🟡",
        "est_warm": "🟢", "uncertain": "🟡", "est_gone": "🔴", "compacted": "🧹"}


def describe(r):
    hit = (" · %d%% hit" % r["hit_rate"]) if r.get("hit_rate") is not None else ""
    if r["state"] == "compacted":
        return "compacted %s ago — next turn writes a fresh prefix" % hms(r["age"])
    if r["state"] == "untracked":
        return "%s cached · %d%% hit · idle %s" % (
            kt(r["cached"]), r.get("hit_rate", 0), hms(r["age"]))
    if r["state"] == "est_warm":
        return "~%s left · %s%s" % (hms(r["left"]), kt(r["cached"]), hit)
    if r["state"] == "uncertain":
        return "maybe still warm (~%d%%) · idle %s%s" % (
            r.get("maybe_pct", 50), hms(r["age"]), hit)
    if r["state"] == "est_gone":
        return "likely evicted — idle %s%s" % (hms(r["age"]), hit)
    if r["state"] == "cold":
        return "cold %s — rewrites %s" % (hms(r["age"]), kt(r["cached"]))
    return "%s left · %s" % (hms(r["left"]), kt(r["cached"]))


def budget_line(b):
    """One line: what compacting everything costs, against what is left."""
    cost = "compacting %d chats ≈ %s%% of the 5h limit" % (
        b["chats"], b["compaction_pct_5h"])
    if b["left_pct_5h"] is None:
        return cost + " (plan usage unknown)"
    return "%s · %s%% left" % (cost, b["left_pct_5h"])


def budget_detail(b):
    """The actionable part: cold chats are what makes compaction expensive."""
    if b["cold_chats"]:
        return "%d cold → %spp of it; reopening one before it chills makes it free" % (
            b["cold_chats"], b["cold_share_pct_5h"])
    return "all warm — their context re-reads from cache for free"


def render_text(rows, b=None):
    if not rows:
        print("no AI sessions in the last %d min" % (LOOKBACK // 60))
        return
    for r in rows[:MAX_ROWS]:
        print("%s %-46s %s" % (ICON[r["state"]], r["display"][:46], describe(r)))
    if b:
        print()
        print(budget_line(b))
        print("  " + budget_detail(b))
        if b["would_exhaust_5h"]:
            print("  ! that would run you out before the 5h window resets")
        if b["reset"]:
            print("  %s limit is capping you now, resets in %s"
                  % (b["reset"]["kind"] or "?", hms(b["reset"]["resets_in"])))


def render_swiftbar(rows, b=None):
    tracked = [r for r in rows if r["ttl_known"]]
    if not tracked:
        print("🫥")
    else:
        t = tracked[0]
        if t["state"] in ("cold", "est_gone", "uncertain"):
            print("%s %s | color=#8899aa" % (ICON[t["state"]], hms(t["age"])))
        else:
            colour = " | color=orange" if t["state"] == "expiring" else ""
            print("%s %s%s%s" % (ICON[t["state"]],
                                 "~" if t.get("ttl_estimate") else "",
                                 hms(t["left"]), colour))
    print("---")
    warm = len([r for r in tracked
                if r["state"] in ("warm", "expiring", "est_warm")])
    print("Prompt cache · %d warm / %d recent | size=11 color=gray" % (warm, len(rows)))
    for r in rows[:MAX_ROWS]:
        print("%s %s  ·  %s" % (ICON[r["state"]], r["display"][:46], describe(r)))
    if b:
        print("---")
        colour = " | color=orange" if b["would_exhaust_5h"] else " | color=gray"
        print("%s%s" % (budget_line(b), colour))
        print("%s | size=11 color=gray" % budget_detail(b))
        if b["reset"]:
            print("%s limit capping now · resets in %s | size=11 color=orange"
                  % (b["reset"]["kind"] or "?", hms(b["reset"]["resets_in"])))
    print("---")
    print("Refresh | refresh=true")


def _notify(title, msg):
    """A plain banner via osascript. Title and body travel as argv, never spliced
    into the script text, so no chat title can inject AppleScript; the "--" stops
    osascript from parsing a title that starts with "-" as one of its options."""
    try:
        subprocess.call(["/usr/bin/osascript",
                         "-e", "on run argv",
                         "-e", "display notification (item 2 of argv)"
                         " with title (item 1 of argv)",
                         "-e", "end run", "--", title, msg])
    except OSError:
        pass


BUDGET_KEY = "__compaction_budget__"


def render_notify(rows, b=None):
    # The first run only records where every chat stands; announcing all of them
    # at once would be noise, not news.
    notify = _notify if os.path.exists(STATE) else (lambda title, msg: None)
    prev = load_json(STATE, {})
    current = {}
    if b:
        # Only on the transition into trouble, so it fires once and not every poll.
        flag = "tight" if b["would_exhaust_5h"] else "ok"
        current[BUDGET_KEY] = flag
        if flag == "tight" and prev.get(BUDGET_KEY, "ok") != "tight":
            cold = [r["display"] for r in rows
                    if r["tool"] == "claude" and r["state"] == "cold"]
            who = ("Cold: " + " · ".join(cold[:2])
                   + (" +%d more" % (len(cold) - 2) if len(cold) > 2 else "")
                   ) if cold else budget_detail(b)
            notify("Compacting everything would exhaust your 5h limit",
                   "%d chats ≈ %s%% but only %s%% left. %s"
                   % (b["chats"], b["compaction_pct_5h"], b["left_pct_5h"], who))
    for r in rows:
        if not r["ttl_known"] or r["age"] > NOTIFY_MAX_AGE or r.get("ttl_estimate"):
            continue  # estimated TTLs (codex) shape the display, never notifications
        current[r["session"]] = r["state"]
        # Cold tax already paid: a fresh prefix rewrite in this session.
        if r.get("rewrite_at"):
            key = "rewrite:" + r["session"]
            current[key] = r["rewrite_at"]
            if prev.get(key) != r["rewrite_at"] and (r.get("rewrite_age") or 0) <= 1800:
                notify(r["display"],
                       "Rewrote %s cached tokens after %s idle — ≈%s%% of the 5h limit."
                       % (kt(r["rewrote"]), hms(r["rewrite_gap"]), r["rewrite_pct_5h"]))
        if prev.get(r["session"], "warm") == r["state"]:
            continue
        # The chat title is the headline — a "Cache expiring:" prefix pushes
        # long titles out of the banner's single bold line.
        ttl = r.get("ttl", DEFAULT_TTL)
        if r["state"] == "expiring":
            notify(r["display"],
                   "Cache expiring — %s left on %s cached. %s"
                   % (hms(r["left"]), kt(r["cached"]),
                      "Any message refreshes the hour." if ttl == 3600
                      else "Any message refreshes its %s TTL." % hms(ttl)))
        elif r["state"] == "cold":
            # list prices: a 1h-tier write is 2x base input, a 5-minute one 1.25x
            notify(r["display"],
                   "Cache went cold — next turn rewrites %s at %s instead of reading at 0.1x."
                   % (kt(r["cached"]), "1.25x" if ttl <= 300 else "2x"))
    save_json(STATE, current)


def main():
    mode = "swiftbar"
    for a in sys.argv[1:]:
        if a in ("--swiftbar", "--notify", "--text", "--json", "--calibrate"):
            mode = a[2:]
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            sys.stderr.write("unknown arg: %s\n" % a)
            return 2
    now = clock()
    if mode == "calibrate":
        out = {"plan": plan_calibration(now, force=True),
               "plan_fit": load_json(PLAN_CAL, None),
               "codex": (codex_calibration(now, force=True)
                         if os.path.isdir(CODEX_SESSIONS) else None)}
        json.dump(out, sys.stdout, indent=2)
        print()
        return 0
    cal = plan_calibration(now)
    paths = claude_transcripts(now)
    rows = collect(now, paths, cal)
    b = budget(rows, now, paths, cal)
    if mode == "json":
        # Wrapper, not a bare array: CacheBar.swift decodes {"sessions", "budget"}
        # and falls back to a bare array for older callers.
        json.dump({"sessions": rows, "budget": b}, sys.stdout, indent=2)
        print()
    elif mode == "text":
        render_text(rows, b)
    elif mode == "notify":
        render_notify(rows, b)
    else:
        render_swiftbar(rows, b)
    return 0


if __name__ == "__main__":
    sys.exit(main())
