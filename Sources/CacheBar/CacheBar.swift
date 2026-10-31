// CacheBar — macOS menu bar item for AI prompt-cache warmth.
//
// Data comes from ai-cache-bar.py --json (bundled into the app at build time),
// which stays the single source of truth for how cache state, chat titles and the
// plan budget are derived, so the rules never fork between this app and the CLI
// surfaces. The app finds a Python 3 to run it with (Python.swift), polls it every
// 15 s, and says in the menu when it can't: no Python, or the script failing, with
// the last good data kept but marked stale.
//
// Notifications use UNUserNotificationCenter when macOS allows it, which takes a
// Developer ID signature: ad-hoc and Apple Development builds get UNErrorDomain
// Code=1 ("Notifications are not allowed for this application"), even registered
// with LaunchServices under a fresh bundle id. Those builds post through the
// deprecated NSUserNotificationCenter instead, which has no such gate and still
// shows the banner as CacheBar, with its icon. A bare binary (`swift run`) has no
// bundle for either and falls back to osascript.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

let appEnv = ProcessInfo.processInfo.environment
/// Test hook: CACHEBAR_TIME_SCALE=30 polls 30x as often.
let timeScale = Double(appEnv["CACHEBAR_TIME_SCALE"] ?? "").flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? 1
let pollEvery: TimeInterval = max(0.1, 15 / timeScale)
/// A poll still running after this is killed; polls never overlap.
let scriptTimeout: TimeInterval = 20
/// `--calibrate` scans up to a month of transcripts: give it room.
let calibrateTimeout: TimeInterval = 600
let debugOn = appEnv["CACHEBAR_DEBUG"] == "1"
/// Test hook: CACHEBAR_NO_BANNERS=1 still logs each notification (CACHEBAR_DEBUG)
/// but delivers none.
let noBanners = appEnv["CACHEBAR_NO_BANNERS"] == "1"
/// Sessions idle longer than this never notify — the script's own --notify knob.
let notifyMaxAge = Int(appEnv["AI_CACHE_NOTIFY_MAX_AGE"] ?? "") ?? 7200
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

/// CACHEBAR_DEBUG=1: one line per event on stderr — `python: <path>`, `poll: …`,
/// `notify: …`, `error: …`.
func debug(_ msg: @autoclosure () -> String) {
    guard debugOn else { return }
    FileHandle.standardError.write("[cachebar] \(msg())\n".data(using: .utf8)!)
}

struct Session: Decodable, Identifiable {
    let tool: String
    let session: String
    let title: String?
    let label: String
    let display: String
    let model: String
    let age: Int
    let left: Int
    let cached: Int
    let ttl_known: Bool
    let ttl_estimate: Bool?
    let maybe_pct: Int?
    let state: String
    let hit_rate: Int?
    let rewrote: Int?
    let rewrite_at: Int?
    let rewrite_age: Int?
    let rewrite_gap: Int?
    let rewrite_pct_5h: Double?
    /// The chat's cache tier in seconds (claude rows; older scripts omit it).
    let ttl: Int?

    var id: String { session }

    var icon: String {
        switch state {
        case "warm": return "🔥"
        case "expiring": return "⚠️"
        case "cold": return "❄️"
        // codex: estimated states get a traffic light, not claude's
        // deterministic fire/snow — past warm_s nothing is knowable.
        case "est_warm": return "🟢"
        case "uncertain": return "🟡"
        case "est_gone": return "🔴"
        case "compacted": return "🧹"
        default: return "🟡"
        }
    }

    var detail: String {
        // Compacted chats are ttl_known == false too, but their story is the
        // compaction, not an untracked cache.
        if state == "compacted" {
            return "compacted \(hms(age)) ago — next turn writes a fresh prefix"
        }
        if !ttl_known {
            return "\(kt(cached)) cached · \(hit_rate ?? 0)% hit · idle \(hms(age))"
        }
        let hit = hit_rate.map { " · \($0)% hit" } ?? ""
        switch state {
        case "est_warm":
            return "~\(hms(left)) left · \(kt(cached))\(hit)"
        case "uncertain":
            return "maybe still warm (~\(maybe_pct ?? 50)%) · idle \(hms(age))\(hit)"
        case "est_gone":
            return "likely evicted — idle \(hms(age))\(hit)"
        case "cold":
            return "cold \(hms(age)) — rewrites \(kt(cached))"
        default:
            return "\(hms(left)) left · \(kt(cached))"
        }
    }
}

/// What compacting every open chat would cost against the plan limits. Percentages
/// come from ai-cache-bar.py, which owns the calibration.
struct Budget: Decodable {
    let chats: Int
    let cold_chats: Int
    let compaction_pct_5h: Double
    let cold_share_pct_5h: Double
    /// Plan percentages are numbers that may be fractional: decoded as Double and
    /// shown rounded.
    let used_pct_5h: Double?
    let left_pct_5h: Double?
    let would_exhaust_5h: Bool
    let reset: Reset?
    let calibration: Calibration?
    /// Seconds since the plan-usage sample the percentages come from.
    let usage_sample_age: Double?

    struct Reset: Decodable {
        let resets_in: Int
        let kind: String?
    }

    /// How the script turns tokens into plan percent: "fitted" to this Mac's usage
    /// history, its built-in "default", or "env" (AI_CACHE_5H_PER_PCT).
    struct Calibration: Decodable {
        let source: String?
        let windows: Int?
        let per_pct_5h: Double?
    }

    enum CodingKeys: String, CodingKey {
        case chats, cold_chats, compaction_pct_5h, cold_share_pct_5h, used_pct_5h, left_pct_5h,
             would_exhaust_5h, reset, calibration, usage_sample_age
    }

    /// The optional fields are lenient: one the script gets wrong (or an older script
    /// lacks) blanks itself instead of failing the whole payload and freezing the menu.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chats = try c.decode(Int.self, forKey: .chats)
        cold_chats = try c.decode(Int.self, forKey: .cold_chats)
        compaction_pct_5h = try c.decode(Double.self, forKey: .compaction_pct_5h)
        cold_share_pct_5h = try c.decode(Double.self, forKey: .cold_share_pct_5h)
        would_exhaust_5h = try c.decode(Bool.self, forKey: .would_exhaust_5h)
        used_pct_5h = try? c.decodeIfPresent(Double.self, forKey: .used_pct_5h)
        left_pct_5h = try? c.decodeIfPresent(Double.self, forKey: .left_pct_5h)
        reset = try? c.decodeIfPresent(Reset.self, forKey: .reset)
        calibration = try? c.decodeIfPresent(Calibration.self, forKey: .calibration)
        usage_sample_age = try? c.decodeIfPresent(Double.self, forKey: .usage_sample_age)
    }

    var line: String {
        let cost = String(format: "compacting %d chats ≈ %.1f%% of the 5h limit",
                          chats, compaction_pct_5h)
        guard let left = left_pct_5h else { return cost + " (plan usage unknown)" }
        // The desktop app samples plan usage every ~5 minutes while it runs.
        let asOf = usage_sample_age.flatMap { $0 > 1800 ? " (usage as of \(ago($0)) ago)" : nil } ?? ""
        return "\(cost) · \(pct(left))% left\(asOf)"
    }

    var detail: String {
        guard cold_chats > 0 else {
            return "all warm — their context re-reads from cache for free"
        }
        return String(format: "%d cold → %.1fpp of it; reopening one before it chills makes it free",
                      cold_chats, cold_share_pct_5h)
    }

    var calibrationNote: String? {
        calibration?.source == "default"
            ? "plan % uses a default calibration until there's enough usage history" : nil
    }
}

/// ai-cache-bar.py --json emits {"sessions", "budget"}; a bare array is still
/// accepted so an older script keeps working.
struct Payload: Decodable {
    let sessions: [Session]
    let budget: Budget?
}

func hms(_ seconds: Int) -> String {
    let s = abs(seconds)
    if s >= 3600 { return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60) }
    if s >= 60 { return "\(s / 60)m" }
    return "\(s)s"
}

func kt(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }

/// How long ago, coarsely: "40s", "3m", "2h", "5d".
func ago(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 48 * 3600 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func pct(_ v: Double) -> String { String(Int(v.rounded())) }

/// A decode failure as a path and a reason: "budget.chats: expected Int".
func describe(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return error.localizedDescription }
    func path(_ keys: [CodingKey]) -> String {
        let p = keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return p.hasPrefix(".") ? String(p.dropFirst()) : p
    }
    switch e {
    case .typeMismatch(let type, let c): return "\(path(c.codingPath)): expected \(type)"
    case .valueNotFound(let type, let c): return "\(path(c.codingPath)): null, expected \(type)"
    case .keyNotFound(let key, let c): return "\(path(c.codingPath + [key])): missing"
    case .dataCorrupted(let c):
        let at = path(c.codingPath)
        return (at.isEmpty ? "" : "\(at): ") + c.debugDescription
    @unknown default: return String(describing: e)
    }
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var useNative = false
    /// The user turned CacheBar's notifications down in the native prompt: respect
    /// that rather than reaching them through the deprecated center instead.
    private var declined = false

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else {
            debug("notifications: osascript (no app bundle)")
            return
        }
        guard !noBanners else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // An error means macOS refuses this signature (anything but a Developer
            // ID); no error and no grant means the user said no.
            let declined = !granted && error == nil
            debug(granted ? "notifications: UNUserNotificationCenter"
                : declined ? "notifications: declined by the user"
                : "notifications: NSUserNotificationCenter (native refused: "
                    + "\(error.map { String(describing: $0) } ?? "")))")
            DispatchQueue.main.async {
                self.useNative = granted
                self.declined = declined
            }
        }
    }

    /// One `group` per session: a session's newer banner replaces its own earlier
    /// one, never another session's.
    func post(title: String, body: String, group: String = "cachebar") {
        debug("notify: \(title) — \(body)")
        if noBanners || declined { return }
        if useNative {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: group, content: content, trigger: nil))
            return
        }
        if Bundle.main.bundleIdentifier != nil {
            LegacyNotifier.shared.post(title: title, body: body, group: group)
            return
        }
        // Title and body travel as arguments, never inside the script text, so a
        // chat title can't break (or inject into) the AppleScript; "--" keeps a
        // title that starts with "-" from being read as an osascript option.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "on run argv",
                          "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                          "-e", "end run", "--", title, body]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    // LSUIElement apps are never "frontmost" in the usual sense; show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completion:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }
}

/// The fallback for builds macOS won't give UNUserNotificationCenter. The
/// deprecated NSUserNotificationCenter asks for no authorization (terminal-notifier
/// relies on the same), and its banners still show as CacheBar, with its icon.
/// Its deprecation warnings are expected; Swift has no way to silence them here.
final class LegacyNotifier: NSObject, NSUserNotificationCenterDelegate {
    static let shared = LegacyNotifier()

    func post(title: String, body: String, group: String) {
        let center = NSUserNotificationCenter.default
        center.delegate = self
        let note = NSUserNotification()
        note.title = title
        note.informativeText = body
        // As with UNNotificationRequest's identifier, a newer notification
        // replaces the one still showing from the same group.
        note.identifier = group
        center.deliver(note)
    }

    /// Show banners even while CacheBar is the active app (its Settings window).
    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        true
    }
}

// MARK: - Settings values

/// What the Settings window saves, in the app's defaults (`defaults read
/// com.michieltimmerman.cachebar`). A nil number leaves the script's own default.
struct Prefs: Equatable {
    var notify = true
    var warnMinutes: Int?
    var maxRows: Int?
    var lookbackHours: Int?

    static func load() -> Prefs {
        let d = UserDefaults.standard
        /// Accepts `defaults write … KEY -int 5` and plain `KEY 5` alike.
        func number(_ key: String) -> Int? {
            let v = d.object(forKey: key)
            let n = (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) }
            return n.flatMap { $0 > 0 ? $0 : nil }
        }
        var p = Prefs()
        if d.object(forKey: "notifications") != nil { p.notify = d.bool(forKey: "notifications") }
        p.warnMinutes = number("warnMinutes")
        p.maxRows = number("maxRows")
        p.lookbackHours = number("lookbackHours")
        return p
    }

    func save() {
        let d = UserDefaults.standard
        d.set(notify, forKey: "notifications")
        for (key, value) in [("warnMinutes", warnMinutes), ("maxRows", maxRows), ("lookbackHours", lookbackHours)] {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    // What the app acts on: a command-line argument wins (Arguments.swift), then the
    // environment, then the saved setting. Never saved.
    var notifies: Bool { overrides.notifications ?? notify }

    var warn: Knob {
        Knob(flag: "--warn-minutes", env: "AI_CACHE_WARN_SECONDS", scale: 60, envSeconds: 1,
             standard: 10, unit: ("minute", "minutes"), argument: overrides.warnMinutes, saved: warnMinutes)
    }
    /// Also the menu's row count; the script's --json lists every chat regardless.
    var rows: Knob {
        Knob(flag: "--max-rows", env: "AI_CACHE_MAX_ROWS", scale: 1, envSeconds: nil,
             standard: 10, unit: ("row", "rows"), argument: overrides.maxRows, saved: maxRows)
    }
    var lookback: Knob {
        Knob(flag: "--lookback-hours", env: "AI_CACHE_LOOKBACK_MIN", scale: 60, envSeconds: 60,
             standard: 4, unit: ("hour", "hours"), argument: overrides.lookbackHours, saved: lookbackHours)
    }

    /// The script's environment: CacheBar's own, with these settings layered over it.
    var scriptEnv: [String: String] {
        var e = appEnv
        for k in [warn, rows, lookback] {
            if let v = k.envValue { e[k.env] = v }
        }
        // The app runs --calibrate itself (`Monitor.calibrateIfDue`).
        e["AI_CACHE_INLINE_FIT"] = "0"
        return e
    }

    /// "notifications on · warn 10 minutes · 10 rows · look back 4 hours", with
    /// where a value came from when it isn't Settings.
    var summary: String {
        func from(_ k: Knob) -> String { k.fixedBy.map { " (\($0))" } ?? "" }
        let n = overrides.notifications != nil ? " (--notifications)" : ""
        return "notifications \(notifies ? "on" : "off")\(n) · warn \(warn.text)\(from(warn))"
            + " · \(rows.text)\(from(rows)) · look back \(lookback.text)\(from(lookback))"
    }
}

/// One number the script reads from its environment. For this run an argument
/// wins, then the environment CacheBar was started with, then Settings; with none
/// of them the script keeps its own default.
struct Knob {
    let flag: String
    let env: String
    /// Environment units per setting unit: 60 turns minutes into seconds.
    let scale: Int
    /// Seconds per environment unit, for showing an inherited duration exactly.
    let envSeconds: Int?
    /// The script's default in setting units, shown while nothing is set.
    let standard: Int
    let unit: (one: String, many: String)
    let argument: Int?
    let saved: Int?

    var inherited: Int? { appEnv[env].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// The flag or variable fixing this for the run; nil when Settings decides.
    var fixedBy: String? { argument != nil ? flag : inherited != nil ? env : nil }

    /// In setting units; an inherited value rounds down, never to zero.
    var value: Int { argument ?? inherited.map { max(1, $0 / scale) } ?? saved ?? standard }

    func label(_ n: Int) -> String { "\(n) \(n == 1 ? unit.one : unit.many)" }

    /// `value` as text, exact for an inherited duration ("20s").
    var text: String {
        if argument == nil, let v = inherited, let s = envSeconds { return hms(v * s) }
        return label(value)
    }

    /// Layered over the inherited environment; nil keeps whatever is inherited.
    var envValue: String? {
        if let a = argument { return String(a * scale) }
        if inherited != nil { return nil }
        return saved.map { String($0 * scale) }
    }
}

// MARK: - Data

enum PollResult {
    case data([Session], Budget?)
    case failed(String)
    /// The interpreter itself would not start (uninstalled since it was found).
    case pythonGone(String)

    static func read(_ r: Ran) -> PollResult {
        if let e = r.launchError { return .pythonGone(e) }
        if let why = r.failure { return .failed("ai-cache-bar.py \(why)") }
        if r.stdout.isEmpty { return .failed("ai-cache-bar.py --json printed nothing") }
        let decoder = JSONDecoder()
        do {
            let payload = try decoder.decode(Payload.self, from: r.stdout)
            return .data(payload.sessions, payload.budget)
        } catch {
            if let bare = try? decoder.decode([Session].self, from: r.stdout) { return .data(bare, nil) }
            return .failed("couldn't read ai-cache-bar.py --json: \(describe(error))")
        }
    }
}

final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var sessions: [Session] = []
    @Published var budget: Budget?
    /// When `sessions` were read; nil until the first good poll.
    @Published var dataAt: Date?
    /// What went wrong on the latest poll. The last good data stays up, marked stale.
    @Published var problem: String?
    @Published var python = PythonLookup.locating
    @Published var prefs = Prefs.load() {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            // A longer look-back brings in chats that were already cold: record
            // them on the next poll instead of announcing them as news.
            if prefs.lookback.envValue != oldValue.lookback.envValue { seeded = false }
            refresh()
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Why Launch at login isn't on, when macOS said no.
    @Published var launchAtLoginNote: String?

    private var dataTitle = "🫥"
    private var lastState: [String: String] = [:]
    private var lastRewriteAt: [String: Int] = [:]
    private var lastBudgetTight = false
    /// The first poll only records state. Without this, launching while sessions are
    /// already cold fires a notification per session for news you did not ask for.
    private var seeded = false
    private var polling = false
    /// Refresh asked for while a poll was running: one more right after it.
    private var pollAgain = false
    private var locating = false
    private var locateAgain = false
    private var calibrating = false
    private var lastCalibration: Date?
    private var timer: Timer?

    func start() {
        Notifier.shared.requestAuthorization()
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            launchAtLoginNote = "Move CacheBar to Applications to enable Launch at login"
        }
        debug("script: \(scriptPath)")
        locate()
        // CACHEBAR_TEST_NOTIFICATION=1 fires one notification a few seconds after
        // launch, once authorization has had a chance to resolve.
        if appEnv["CACHEBAR_TEST_NOTIFICATION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.sendTestNotification() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollEvery, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        switch python {
        case .found: poll()
        case .locating: break
        // Look again in case one was installed meanwhile (xcode-select --install).
        case .none, .unusable: locate()
        }
    }

    /// Find a Python off the main thread, then poll. Also run when Settings changes
    /// the override, and on every tick while none is usable.
    func locate() {
        guard !locating else {
            locateAgain = true
            return
        }
        locating = true
        let remembered = UserDefaults.standard.string(forKey: rememberedPythonKey)
        DispatchQueue.global(qos: .utility).async {
            let found = Pythons.resolve(remembered: remembered)
            DispatchQueue.main.async { self.located(found) }
        }
    }

    private func located(_ found: PythonLookup) {
        locating = false
        if locateAgain {
            locateAgain = false
            locate()
            return
        }
        let changed = found != python
        python = found
        switch found {
        case .found(let py):
            if changed { debug("python: \(py.path)") }
            if py.source == "detected" { UserDefaults.standard.set(py.path, forKey: rememberedPythonKey) }
            calibrateIfDue(py)
            refresh()
        case .none:
            if changed { debug("error: no usable Python 3 found") }
        case .unusable(let path, let source, let why):
            if changed { debug("error: python \(path) (\(originPhrase(source))) is not usable: \(why)") }
        case .locating:
            break
        }
    }

    /// Settings changed the Python override, or asked to look again.
    func pythonSettingChanged() {
        python = .locating
        locate()
    }

    /// Remeasure the plan and codex calibrations at launch and then daily, off the
    /// poll path: polls tell the script not to measure inline (AI_CACHE_INLINE_FIT
    /// in `Prefs.scriptEnv`), because a scan of a large history could outlast the
    /// poll timeout and be killed every time.
    private func calibrateIfDue(_ py: Python) {
        guard !calibrating, lastCalibration.map({ Date().timeIntervalSince($0) >= 86400 }) ?? true
        else { return }
        let env = prefs.scriptEnv
        let script = scriptPath
        guard FileManager.default.fileExists(atPath: script) else { return }
        calibrating = true
        lastCalibration = Date()
        DispatchQueue.global(qos: .background).async { [weak self] in
            let r = runTool(py.path, [script, "--calibrate"], env: env, timeout: calibrateTimeout)
            if let why = r.failure { debug("error: ai-cache-bar.py --calibrate \(why)") }
            DispatchQueue.main.async { self?.calibrating = false }
        }
    }

    /// Poll now (menu, Settings): right after the running poll, if there is one.
    func refresh() {
        if polling { pollAgain = true } else { poll() }
    }

    /// The 15 s cadence. A poll still running (a slow or hung script) is never
    /// overlapped; it is killed at `scriptTimeout`.
    private func poll() {
        guard case .found(let py) = python, !polling else { return }
        calibrateIfDue(py)
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            fail(appEnv["CACHEBAR_SCRIPT"] != nil
                 ? "CACHEBAR_SCRIPT: \(scriptPath) does not exist"
                 : "ai-cache-bar.py is missing (\(scriptPath)) — reinstall CacheBar")
            return
        }
        polling = true
        let env = prefs.scriptEnv
        let script = scriptPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = PollResult.read(runTool(py.path, [script, "--json"], env: env, timeout: scriptTimeout))
            DispatchQueue.main.async { self?.finish(result, python: py) }
        }
    }

    private func finish(_ result: PollResult, python py: Python) {
        polling = false
        switch result {
        case .data(let rows, let b):
            problem = nil
            apply(rows, b)
        case .failed(let why):
            fail(why)
        case .pythonGone(let why):
            fail("\(py.path) could not start: \(why)")
            // Uninstalled or moved since it was found (a Homebrew or mise upgrade).
            if py.source == "detected" { UserDefaults.standard.removeObject(forKey: rememberedPythonKey) }
            pythonSettingChanged()
            return
        }
        if pollAgain {
            pollAgain = false
            poll()
        }
    }

    private func fail(_ why: String) {
        problem = why
        debug("error: \(why)")
    }

    private func apply(_ rows: [Session], _ newBudget: Budget?) {
        sessions = rows
        budget = newBudget
        dataAt = Date()
        let counts = Dictionary(grouping: rows, by: \.state)
            .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        debug("poll: \(rows.count) sessions" + (counts.isEmpty ? "" : " \(counts)"))
        if let top = rows.first(where: { $0.ttl_known }) {
            let est = (top.ttl_estimate ?? false) ? "~" : ""
            dataTitle = ["cold", "est_gone", "uncertain"].contains(top.state)
                ? "\(top.icon) \(hms(top.age))"
                : "\(top.icon) \(est)\(hms(top.left))"
        } else {
            dataTitle = "🫥"
        }

        let notify = prefs.notifies
        for row in rows where row.ttl_known && row.age < notifyMaxAge && !(row.ttl_estimate ?? false) {
            // Cold tax already paid: a fresh prefix rewrite in this session.
            if let wrote = row.rewrote, let at = row.rewrite_at {
                let isNew = lastRewriteAt[row.session] != at
                lastRewriteAt[row.session] = at
                if seeded, isNew, (row.rewrite_age ?? .max) <= 1800, notify {
                    Notifier.shared.post(
                        title: row.display,
                        body: "Rewrote \(kt(wrote)) cached tokens after \(hms(row.rewrite_gap ?? 0)) idle — "
                            + "≈\(String(format: "%.1f", row.rewrite_pct_5h ?? 0))% of the 5h limit.",
                        group: "cachebar-rewrite-\(row.session)")
                }
            }
            let was = lastState[row.session] ?? "warm"
            lastState[row.session] = row.state
            guard seeded, was != row.state, notify else { continue }
            // The chat title is the headline — a "Cache expiring:" prefix pushes
            // long titles out of the banner's single bold line.
            // Same wording as the script's --notify: list prices make a 1h-tier
            // write 2x base input and a 5-minute one 1.25x.
            let ttl = row.ttl ?? 3600
            if row.state == "expiring" {
                let refresh = ttl == 3600 ? "Any message refreshes the hour."
                    : "Any message refreshes its \(hms(ttl)) TTL."
                Notifier.shared.post(
                    title: row.display,
                    body: "Cache expiring — \(hms(row.left)) left on \(kt(row.cached)) cached. \(refresh)",
                    group: "cachebar-\(row.session)")
            } else if row.state == "cold" {
                Notifier.shared.post(
                    title: row.display,
                    body: "Cache went cold — next turn rewrites \(kt(row.cached)) at \(ttl <= 300 ? "1.25x" : "2x") "
                        + "instead of reading at 0.1x.",
                    group: "cachebar-\(row.session)")
            }
        }
        if let b = newBudget {
            let tight = b.would_exhaust_5h
            if seeded, tight, !lastBudgetTight, notify {
                let cold = rows.filter { $0.ttl_known && $0.state == "cold" }.map(\.display)
                let who = cold.isEmpty ? b.detail
                    : "Cold: " + cold.prefix(2).joined(separator: " · ")
                      + (cold.count > 2 ? " +\(cold.count - 2) more" : "")
                Notifier.shared.post(
                    title: "Compacting everything would exhaust your 5h limit",
                    body: "\(b.chats) chats ≈ \(String(format: "%.1f", b.compaction_pct_5h))% "
                        + "but only \(b.left_pct_5h.map(pct) ?? "?")% left. \(who)",
                    group: "cachebar-budget")
            }
            lastBudgetTight = tight
        }
        seeded = true
    }

    /// Verifies delivery end to end, and triggers the authorization prompt on a
    /// first run.
    func sendTestNotification() {
        Notifier.shared.post(
            title: "CacheBar test notification",
            body: "Delivery works.")
    }

    /// The system owns this state; the toggle snaps back to what is registered,
    /// and the menu says why when macOS refused.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginNote = nil
        } catch {
            launchAtLoginNote = "Launch at login: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginNote = "Allow CacheBar under Login Items in System Settings"
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Menu text

    var warmCount: Int {
        sessions.filter {
            $0.ttl_known && ["warm", "expiring", "est_warm"].contains($0.state)
        }.count
    }

    var shownSessions: ArraySlice<Session> { sessions.prefix(prefs.rows.value) }

    var title: String {
        switch python {
        case .none, .unusable: return "⚠️ no Python"
        case .locating, .found: break
        }
        if problem != nil { return dataAt == nil ? "⚠️" : "\(dataTitle) ?" }
        return dataAt == nil ? "…" : dataTitle
    }

    /// What's wrong, for the top of the menu; empty when nothing is.
    var problemLines: [String] {
        var lines: [String] = []
        switch python {
        case .none:
            lines = ["⚠️ No Python 3 found — CacheBar needs one to read your chats",
                     "Install Apple's Command Line Tools: xcode-select --install",
                     "…or pick a python3 in Settings"]
        case .unusable(let path, let source, let why):
            lines = ["⚠️ The python3 \(originPhrase(source)) isn't usable: \(why)",
                     path,
                     "Clear it or pick another in Settings"]
        case .locating, .found:
            if let p = problem { lines = ["⚠️ " + (p.count > 140 ? String(p.prefix(139)) + "…" : p)] }
        }
        if !lines.isEmpty, let at = dataAt {
            lines.append("Showing data as of \(ago(Date().timeIntervalSince(at))) ago")
        }
        return lines
    }
}

// MARK: - CLI

/// `CacheBar --status`: the Python the app would use, and what ai-cache-bar.py
/// --text shows under this run's settings. Non-zero when either half is missing.
func printStatus() -> Int32 {
    func fail(_ msg: String) -> Int32 {
        fflush(stdout)
        FileHandle.standardError.write("CacheBar: \(msg)\n".data(using: .utf8)!)
        return 1
    }
    let prefs = Prefs.load()
    switch Pythons.resolve(remembered: UserDefaults.standard.string(forKey: rememberedPythonKey)) {
    case .found(let py):
        print("python:   \(py.path) (Python \(py.version), \(py.origin))")
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return fail("ai-cache-bar.py not found at \(scriptPath)")
        }
        print("script:   \(scriptPath)")
        print("settings: \(prefs.summary)")
        print("")
        let r = runTool(py.path, [scriptPath, "--text"], env: prefs.scriptEnv, timeout: scriptTimeout)
        print(String(decoding: r.stdout, as: UTF8.self), terminator: "")
        guard let why = r.failure else { return 0 }
        fflush(stdout)
        if !r.stderr.isEmpty { FileHandle.standardError.write(r.stderr.data(using: .utf8)!) }
        return fail("ai-cache-bar.py --text \(why)")
    case .unusable(let path, let source, let why):
        return fail("the python3 \(originPhrase(source)) (\(path)) isn't usable: \(why)")
    case .none, .locating:
        return fail("no Python 3 found. Install Apple's Command Line Tools (xcode-select --install), "
                    + "or name one with --python PATH, CACHEBAR_PYTHON or Settings.")
    }
}

// MARK: - Menu

@main
struct CacheBarApp: App {
    @StateObject private var monitor = Monitor.shared

    init() {
        do {
            launchArguments = try Arguments.parse(CommandLine.arguments)
        } catch let e as Arguments.Invalid {
            FileHandle.standardError.write("CacheBar: \(e.message)\n\n\(Arguments.usage)\n".data(using: .utf8)!)
            exit(2)
        } catch {
            exit(2)
        }
        switch launchArguments.command {
        case .help:
            print(Arguments.usage)
            exit(0)
        case .version:
            print(appVersion)
            exit(0)
        case .status:
            exit(printStatus())
        case .run:
            Monitor.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text("Prompt cache · \(monitor.warmCount) warm / \(monitor.sessions.count) recent")
            ForEach(monitor.problemLines, id: \.self) { Text($0) }
            Divider()
            // Rows are information, not actions — nothing is safe to open on
            // click (README.md: deep links), so they are plain text.
            ForEach(monitor.shownSessions) { s in
                Text("\(s.icon)  \(s.display)  ·  \(s.detail)")
            }
            if monitor.sessions.count > monitor.shownSessions.count {
                Text("+\(monitor.sessions.count - monitor.shownSessions.count) more")
            }
            if let b = monitor.budget {
                Divider()
                Text(b.line)
                Text(b.detail)
                if let note = b.calibrationNote { Text(note) }
                if let r = b.reset {
                    Text("\(r.kind ?? "?") limit capping now · resets in \(hms(r.resets_in))")
                }
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { monitor.setLaunchAtLogin($0) }))
            if let note = monitor.launchAtLoginNote { Text(note) }
            Button("Refresh now") { monitor.refresh() }
            Button("Send test notification") { monitor.sendTestNotification() }
            Divider()
            Button("Settings…") { SettingsWindow.shared.show() }
                .keyboardShortcut(",")
            Button("Quit CacheBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Text(monitor.title)
        }
    }
}
