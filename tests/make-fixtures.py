#!/usr/bin/python3
"""make-fixtures.py DIR [--now EPOCH] [--thin-history] [--no-quota]

Builds a deterministic fake HOME under DIR for ai-cache-bar.py — the input of the
golden tests (tests/script-tests.sh) and of the demo data. Prints the epoch it
built against; run the script with HOME=DIR AI_CACHE_NOW=<that epoch>.

Everything is relative to --now (default 2026-10-01T12:00:00Z), file mtimes
included, so the same --now always yields the same bytes. Titles, paths and
prompts are made up.

Claude (~/.claude/projects), today's sessions, newest turn first:
  Quick lint fixes        5-minute tier (the newest cache write flipped from 1h)
  Refactor parser tests   warm; custom title beats its ai-title; last turn written
                          as three content-block lines; has a newer subagent
                          transcript (excluded from rows, counted in the budget)
  Migrate config loader   warm, but its last turn paid the cold tax (rewrite)
  Add export command      two transcripts in one leased worktree (git-worktrees.json)
                          collapse to the fresher one
  Summarise design doc    compacted after its last turn
  Draft release notes     expiring; ai-title only
  Tune flaky integration  cold; its newest line is a synthetic rate-limit
  test                    rejection carrying quotaLimits (--no-quota drops it)
Plus history transcripts from 2-12 days ago (outside the 4h lookback) whose
turns are duplicated per content block, as Claude Code writes them.

Plan usage (plan-usage-history.json): samples simulated from a fake server that
opens a five-hour window at the first message after the last one closed and
charges U / 120000 percent per window (seven-day: U / 1005587) — i.e. this
fixture's plan is NOT the script's default 179000, so the "fitted" path shows.
Windows: 8 usable ones, one censored at 100%, one too small, one cut short by
a reset caused by usage from "another device" (never in the transcripts), and
one sample from another org. --thin-history keeps one history window, leaving
too few for a fit (the "default" path).

Codex (~/.codex): one warm session, one resumed across two rollout files and
renamed in session_index.jsonl (uncertain), one unnamed and long idle.
"""
import json
import os
import sys
import time
import uuid

DEFAULT_NOW = 1790856000  # 2026-10-01T12:00:00Z
D_5H = 120000    # the fixture plan's weighted tokens per 1% of the five-hour limit
D_7D = 1005587   # 1500000 * 120000 / 179000: the script's 7d scaling assumption
ORG = "org-fixture"

MIN = 60
HOUR = 3600
DAY = 86400

WEIGHTS = (("fable", 2.0), ("opus", 1.0), ("sonnet", 0.4), ("haiku", 0.2))

OPUS = "claude-opus-5"
FABLE = "claude-fable-5"
SONNET = "claude-sonnet-5"


def weight(model):
    for key, w in WEIGHTS:
        if key in model:
            return w
    return 1.0


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".000Z"


def sid_for(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "cachebar-fixture/" + name))


def project_dir(cwd):
    return cwd.replace("/", "-").replace(".", "-")


class Fixture(object):
    def __init__(self, root, now):
        self.root = root
        self.now = now
        self.ledger = []   # (t, U) per API response: what the fake server charges
        self.seq = 0

    def next_id(self):
        self.seq += 1
        return self.seq

    def write(self, rel, lines, mtime):
        path = os.path.join(self.root, rel)
        if not os.path.isdir(os.path.dirname(path)):
            os.makedirs(os.path.dirname(path))
        with open(path, "w") as fh:
            for line in lines:
                fh.write(line if isinstance(line, str)
                         else json.dumps(line, separators=(",", ":")))
                fh.write("\n")
        os.utime(path, (mtime, mtime))
        return path


class Transcript(object):
    """One Claude Code .jsonl: entries in the shape Claude Code writes them."""

    def __init__(self, fx, name, cwd, branch, model, sidechain=False, sid=None):
        self.fx, self.cwd, self.branch, self.model = fx, cwd, branch, model
        self.sidechain = sidechain
        self.sid = sid or sid_for(name)
        self.entries = []

    def _base(self, t, kind):
        n = self.fx.next_id()
        return {"parentUuid": None, "isSidechain": self.sidechain,
                "type": kind, "uuid": "00000000-0000-4000-8000-%012d" % n,
                "timestamp": iso(t), "cwd": self.cwd, "sessionId": self.sid,
                "version": "2.0.0", "gitBranch": self.branch}

    def user(self, t):
        e = self._base(t, "user")
        e["message"] = {"role": "user", "content": "(fixture prompt)"}
        self.entries.append((t, e))

    def turn(self, t, inp=4, read=0, w1=0, w5=0, out=600, blocks=1, partial=False,
             model=None):
        """One API response; `blocks` lines repeating its usage, optionally after
        a streaming partial with a smaller output count."""
        model = model or self.model
        n = self.fx.next_id()
        mid, rid = "msg_fixture%06d" % n, "req_fixture%06d" % n

        def usage(o):
            return {"input_tokens": inp, "cache_creation_input_tokens": w1 + w5,
                    "cache_read_input_tokens": read,
                    "cache_creation": {"ephemeral_5m_input_tokens": w5,
                                       "ephemeral_1h_input_tokens": w1},
                    "output_tokens": o, "service_tier": "standard"}

        lines = ([usage(max(1, out // 10))] if partial else []) + [usage(out)] * blocks
        for i, u in enumerate(lines):
            e = self._base(t, "assistant")
            e["message"] = {"model": model, "id": mid, "type": "message",
                            "role": "assistant",
                            "content": [{"type": "text", "text": "(fixture reply)"}],
                            "stop_reason": "end_turn" if i == len(lines) - 1 else None,
                            "usage": u}
            e["requestId"] = rid
            self.entries.append((t, e))
        self.fx.ledger.append((t, weight(model) * (inp + w5 + 1.6 * w1 + 14 * out)))

    def title(self, kind, text):
        key = "customTitle" if kind == "custom-title" else "aiTitle"
        self.entries.append((None, {"type": kind, key: text, "sessionId": self.sid}))

    def compact(self, t):
        e = self._base(t, "user")
        e["isCompactSummary"] = True
        e["message"] = {"role": "user", "content": "(fixture summary)"}
        self.entries.append((t, e))
        stub = self._base(t, "assistant")  # synthetic, all-zero usage, no requestId
        stub["message"] = {"model": "<synthetic>", "id": "msg_compact%06d" % self.fx.next_id(),
                           "role": "assistant", "content": [],
                           "usage": {"input_tokens": 0, "output_tokens": 0,
                                     "cache_creation_input_tokens": 0,
                                     "cache_read_input_tokens": 0}}
        self.entries.append((t, stub))

    def quota(self, t, resets_at):
        """A rejected request: synthetic assistant entry WITH a requestId."""
        e = self._base(t, "assistant")
        n = self.fx.next_id()
        e["message"] = {"model": "<synthetic>", "id": "msg_error%06d" % n,
                        "role": "assistant",
                        "content": [{"type": "text", "text": "(fixture limit notice)"}],
                        "usage": {"input_tokens": 0, "output_tokens": 0,
                                  "cache_creation_input_tokens": 0,
                                  "cache_read_input_tokens": 0}}
        e["requestId"] = "req_error%06d" % n
        e["isApiErrorMessage"] = True
        e["quotaLimits"] = {"status": "rejected", "resetsAt": int(resets_at),
                            "rateLimitType": "five_hour", "overageStatus": "rejected",
                            "overageDisabledReason": "org_level_disabled",
                            "isUsingOverage": False}
        self.entries.append((t, e))

    def save(self, rel=None):
        if rel is None:
            rel = os.path.join(".claude", "projects", project_dir(self.cwd),
                               self.sid + ".jsonl")
        mtime = max(t for t, _ in self.entries if t is not None)
        return self.fx.write(rel, [e for _, e in self.entries], mtime)


def today(fx, quota):
    now = fx.now

    s = Transcript(fx, "lint", "/Users/demo/src/lint", "main", SONNET)
    s.user(now - 31 * MIN)
    s.turn(now - 30 * MIN, w1=40000, out=900)
    s.turn(now - 20 * MIN, read=40000, w1=3000, out=700)
    s.turn(now - 5 * MIN, read=43000, w5=2500, out=500)
    s.turn(now - 2 * MIN, read=45500, w5=1800, out=600)
    s.title("ai-title", "Quick lint fixes")
    s.save()

    s = Transcript(fx, "parser", "/Users/demo/src/parser", "main", OPUS)
    s.title("ai-title", "Parser test cleanup")
    s.user(now - 51 * MIN)
    s.turn(now - 50 * MIN, w1=30000, out=1200)
    s.turn(now - 15 * MIN, read=360000, w1=12000, out=900)
    s.title("custom-title", "Refactor parser tests")
    s.turn(now - 8 * MIN, read=372000, w1=12000, out=1500, blocks=3, partial=True)
    s.save()
    sub = Transcript(fx, "parser-agent", "/Users/demo/src/parser", "main", SONNET,
                     sidechain=True, sid=s.sid)
    sub.turn(now - 12 * MIN, w5=24000, out=2000)
    sub.turn(now - 10 * MIN, read=24000, w5=6000, out=2500, blocks=2)
    sub.turn(now - 6 * MIN, read=30000, w5=5000, out=1800)
    sub.save(os.path.join(".claude", "projects", project_dir(s.cwd), s.sid,
                          "subagents", "agent-a1b2c3d4.jsonl"))

    s = Transcript(fx, "config", "/Users/demo/src/config", "main", FABLE)
    s.title("custom-title", "Migrate config loader")
    s.turn(now - 3 * HOUR, w1=240000, out=2000)
    s.turn(now - 2 * HOUR - 55 * MIN, read=248000, w1=4000, out=1500)
    s.turn(now - 12 * MIN, read=3000, w1=252000, out=1800)  # 2h43m idle: cold tax
    s.save()

    wt = "/Users/demo/src/cachebar/.claude/worktrees/export-cmd"
    s = Transcript(fx, "export-1", wt, "export-cmd", OPUS)
    s.title("custom-title", "Add export command")
    s.turn(now - 80 * MIN, w1=90000, out=1400)
    s.turn(now - 35 * MIN, read=90000, w1=8000, out=1100)
    s.save()
    s = Transcript(fx, "export-2", wt + "/Sources", "export-cmd", OPUS)  # resumed
    s.title("custom-title", "Add export command")
    s.turn(now - 25 * MIN, w1=104000, out=1300)
    s.turn(now - 18 * MIN, read=104000, w1=6000, out=1000)
    s.save()

    s = Transcript(fx, "docs", "/Users/demo/src/docs", "main", OPUS)
    s.title("custom-title", "Summarise design doc")
    s.turn(now - 70 * MIN, w1=300000, out=2200)
    s.turn(now - 40 * MIN, read=300000, w1=18000, out=2500)
    s.compact(now - 6 * MIN)
    s.save()

    s = Transcript(fx, "website", "/Users/demo/src/website", "release-notes", SONNET)
    s.turn(now - 90 * MIN, w1=50000, out=1600)
    s.turn(now - 54 * MIN, read=118000, w1=2000, out=800)
    s.title("ai-title", "Draft release notes")
    s.save()

    s = Transcript(fx, "api", "/Users/demo/src/api", "fix-flaky-test", OPUS)
    s.title("custom-title", "Tune flaky integration test")
    s.turn(now - 160 * MIN, w1=200000, out=1800)
    s.turn(now - 130 * MIN, read=205000, w1=12000, out=1100)
    if quota:
        s.quota(now - 125 * MIN, now + 2 * HOUR)
    s.save()

    fx.write(os.path.join("Library", "Application Support", "Claude",
                          "git-worktrees.json"),
             [{"schemaVersion": 1, "worktrees": {
                 "export-cmd": {"name": "export-cmd", "path": wt,
                                "leasedBy": "local_" + sid_for("app-export"),
                                "baseRepo": "/Users/demo/src/cachebar",
                                "branch": "export-cmd"},
                 "cachebar": {"name": "cachebar", "path": "/Users/demo/src/cachebar",
                              "leasedBy": "local_" + sid_for("app-repo"),
                              "baseRepo": "/Users/demo/src/cachebar", "branch": "main"},
                 "spare": {"name": "spare", "path": "/Users/demo/src/spare",
                           "leasedBy": None, "baseRepo": "/Users/demo/src/spare",
                           "branch": "main"}}}],
             now - DAY)


def history(fx, thin):
    """Past windows: (days ago, model, turns, minutes apart, first turn's offset
    from 08:00Z that day). Each turn: 108000 U at weight 1."""
    windows = [(2, OPUS, 9, 20, 0)]
    if not thin:
        windows += [(3, OPUS, 14, 12, 0),       # + a subagent, below
                    (5, FABLE, 12, 15, 0),
                    (6, SONNET, 30, 8, 0),
                    (8, OPUS, 40, 6, 0),
                    (9, OPUS, 120, 2, 0),       # censored at 100%
                    (11, OPUS, 2, 20, 0),       # peaks below 5%
                    (12, OPUS, 12, 20, 65)]     # opened 3h earlier elsewhere
    other = []   # usage from "another device": charged, never in a transcript
    day0 = fx.now - 4 * HOUR  # 08:00Z on --now's day
    for days, model, n, gap, offset in windows:
        t0 = day0 - days * DAY + offset * MIN
        s = Transcript(fx, "history-%d" % days, "/Users/demo/src/history-%d" % days,
                       "main", model)
        for k in range(n):
            s.turn(t0 + k * gap * MIN, inp=2000, read=150000, w1=40000, out=3000,
                   blocks=2, partial=(k % 3 == 0))
        s.save()
        if days == 3:
            a = Transcript(fx, "history-3-agent", s.cwd, "main", SONNET,
                           sidechain=True, sid=s.sid)
            for k in range(10):
                a.turn(t0 + 10 * MIN + k * 9 * MIN, inp=1500, w5=30000, out=2500)
            a.save(os.path.join(".claude", "projects", project_dir(s.cwd), s.sid,
                                "subagents", "agent-e5f6a7b8.jsonl"))
        if days == 12:
            other.append((t0 - offset * MIN - 3 * HOUR, 24000))
    return other


def server_samples(fx, other):
    """Replay all charged usage through a fake server; sample its percentages."""
    events = sorted(fx.ledger + other)
    windows = []   # [start, [(t, U)]]
    for t, u in events:
        if not windows or t >= windows[-1][0] + 5 * HOUR:
            windows.append([t, []])
        windows[-1][1].append((t, u))
    week = fx.now - 6 * DAY - 12 * HOUR  # a weekly reset 6.5 days before --now
    times = set()
    for start, _ in windows:
        k = start + 10 * MIN
        while k < start + 5 * HOUR:
            times.add(k)
            k += 30 * MIN
        times.add(start + 5 * HOUR + 10 * MIN)
    times.add(fx.now - 2 * MIN)
    samples = []
    for t in sorted(x for x in times if x <= fx.now):
        fh = 0
        for start, evs in windows:
            if start <= t < start + 5 * HOUR:
                fh = int(min(100, sum(u for at, u in evs if at <= t) / D_5H) + 0.5)
        wk = week - 7 * DAY * -(-(week - t) // (7 * DAY))  # last reset at or before t
        sd = int(min(100, sum(u for at, u in events if wk <= at <= t) / D_7D) + 0.5)
        samples.append({"t": int(t * 1000), "org": ORG, "u": {"fh": fh, "sd": sd}})
    # One reading from another account mid-window: must not count as a peak.
    probe = fx.now - 4 * HOUR - 8 * DAY + 2 * HOUR + 5 * MIN
    samples.append({"t": int(probe * 1000), "org": "org-other", "u": {"fh": 97, "sd": 60}})
    samples.sort(key=lambda s: s["t"])
    fx.write(os.path.join("Library", "Application Support", "Claude",
                          "plan-usage-history.json"),
             [json.dumps({"version": 2, "samples": samples})], fx.now - 2 * MIN)


def codex(fx):
    now = fx.now
    day = time.strftime("%Y/%m/%d", time.gmtime(now))

    def rollout(sid, cwd, started, turns, branch="main"):
        name = "rollout-%s-%s.jsonl" % (
            time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime(started)), sid)
        lines = [{"timestamp": iso(started), "type": "session_meta",
                  "payload": {"id": sid, "timestamp": iso(started), "cwd": cwd,
                              "originator": "codex_cli_rs", "cli_version": "0.50.0",
                              "git": {"branch": branch}}}]
        for t, inp, cached in turns:
            lines.append({"timestamp": iso(t), "type": "event_msg",
                          "payload": {"type": "token_count", "info": {
                              "last_token_usage": {"input_tokens": inp,
                                                   "cached_input_tokens": cached,
                                                   "output_tokens": 900}}}})
        fx.write(os.path.join(".codex", "sessions", day, name), lines,
                 max(t for t, _, _ in turns))

    a, b, c = sid_for("codex-onboarding"), sid_for("codex-bench"), sid_for("codex-inventory")
    rollout(a, "/Users/demo/src/onboarding", now - 30 * MIN,
            [(now - 28 * MIN, 30000, 0), (now - 15 * MIN, 36000, 29000),
             (now - 5 * MIN, 42000, 38000)])
    rollout(b, "/Users/demo/src/encoder", now - 3 * HOUR,
            [(now - 175 * MIN, 20000, 0), (now - 150 * MIN, 26000, 19000)])
    rollout(b, "/Users/demo/src/encoder", now - 26 * MIN,   # the resume
            [(now - 25 * MIN, 52000, 12000)])
    rollout(c, "/Users/demo/src/inventory", now - 2 * HOUR,
            [(now - 110 * MIN, 18000, 0), (now - 100 * MIN, 21000, 17500)])
    fx.write(os.path.join(".codex", "session_index.jsonl"),
             [{"id": a, "thread_name": "Sketch onboarding flow",
               "updated_at": iso(now - 5 * MIN)},
              {"id": b, "thread_name": "Benchmark encoder",
               "updated_at": iso(now - 150 * MIN)},
              {"id": b, "thread_name": "Benchmark JSON encoder",
               "updated_at": iso(now - 25 * MIN)}],
             now - 5 * MIN)


def main(argv):
    args, now, thin, quota = [], DEFAULT_NOW, False, True
    it = iter(argv)
    for a in it:
        if a == "--now":
            now = int(float(next(it)))
        elif a == "--thin-history":
            thin = True
        elif a == "--no-quota":
            quota = False
        elif a.startswith("-"):
            sys.stderr.write(__doc__)
            return 2
        else:
            args.append(a)
    if len(args) != 1:
        sys.stderr.write(__doc__)
        return 2
    root = args[0]
    if os.path.isdir(root) and os.listdir(root):
        sys.stderr.write("refusing to build into a non-empty directory: %s\n" % root)
        return 2
    fx = Fixture(root, now)
    today(fx, quota)
    other = history(fx, thin)
    server_samples(fx, other)
    codex(fx)
    print(now)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
