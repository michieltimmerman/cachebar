// CacheBar — macOS menu bar item for AI prompt-cache warmth.
//
// Data comes from ai-cache-bar.py --json (bundled into the app at build time),
// which stays the single source of truth for how cache state, chat titles and the
// plan budget are derived, so the rules never fork between this app and the CLI
// surfaces.
//
// Notifications: it asks for UNUserNotificationCenter first, which would show
// alerts as CacheBar itself and list it in System Settings > Notifications. macOS
// refuses that here — requestAuthorization returns UNErrorDomain Code=1
// ("Notifications are not allowed for this application") even signed with an Apple
// Development identity, registered with LaunchServices, under a fresh bundle id.
// Local notifications need a Developer ID / notarized app. So delivery goes through
// terminal-notifier, which keeps click-to-open via -execute; the native path
// switches on by itself if this ever gets a Developer ID signature.
import SwiftUI
import UserNotifications

struct Session: Codable, Identifiable {
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
    let state: String
    let hit_rate: Int?
    let path: String

    var id: String { session }

    var icon: String {
        switch state {
        case "warm": return "🔥"
        case "expiring": return "⚠️"
        case "cold": return "❄️"
        default: return "🟡"
        }
    }

    var detail: String {
        if !ttl_known {
            return "\(kt(cached)) cached · \(hit_rate ?? 0)% hit · idle \(hms(age))"
        }
        if state == "cold" {
            return "cold \(hms(age)) — rewrites \(kt(cached))"
        }
        return "\(hms(left)) left · \(kt(cached))"
    }
}

/// What compacting every open chat would cost against the plan limits. Percentages
/// come from ai-cache-bar.py, which owns the calibration.
struct Budget: Codable {
    let chats: Int
    let cold_chats: Int
    let compaction_pct_5h: Double
    let cold_share_pct_5h: Double
    let used_pct_5h: Int?
    let left_pct_5h: Int?
    let would_exhaust_5h: Bool
    let reset: Reset?

    struct Reset: Codable {
        let resets_in: Int
        let kind: String?
    }

    var line: String {
        let cost = String(format: "compacting %d chats ≈ %.1f%% of the 5h limit",
                          chats, compaction_pct_5h)
        guard let left = left_pct_5h else { return cost + " (plan usage unknown)" }
        return "\(cost) · \(left)% left"
    }

    var detail: String {
        guard cold_chats > 0 else {
            return "all warm — their context re-reads from cache for free"
        }
        return String(format: "%d cold → %.1fpp of it; reopening one before it chills makes it free",
                      cold_chats, cold_share_pct_5h)
    }
}

/// ai-cache-bar.py --json emits {"sessions", "budget"}; a bare array is still
/// accepted so an older script keeps working.
struct Payload: Codable {
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

/// No claude:// deep link can safely focus an existing chat (see README.md), so
/// "opening" a session reveals its transcript in Finder.
func reveal(transcript: String) {
    guard !transcript.isEmpty else { return }
    NSWorkspace.shared.selectFile(transcript, inFileViewerRootedAtPath: "")
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var useNative = false
    private let fallback = "/opt/homebrew/bin/terminal-notifier"

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if ProcessInfo.processInfo.environment["CACHEBAR_DEBUG"] == "1" {
                let msg = "auth granted=\(granted) error=\(error.map { String(describing: $0) } ?? "nil")\n"
                FileHandle.standardError.write(msg.data(using: .utf8)!)
                center.getNotificationSettings { s in
                    let m = "settings authorization=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue)\n"
                    FileHandle.standardError.write(m.data(using: .utf8)!)
                }
            }
            DispatchQueue.main.async { self.useNative = granted }
        }
    }

    func post(title: String, body: String, transcript: String = "",
              group: String = "cachebar") {
        if useNative {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["transcript": transcript]
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                               content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            postViaFallback(title: title, body: body, transcript: transcript, group: group)
        }
    }

    private func postViaFallback(title: String, body: String,
                                transcript: String = "", group: String = "cachebar") {
        let proc = Process()
        if FileManager.default.isExecutableFile(atPath: fallback) {
            proc.executableURL = URL(fileURLWithPath: fallback)
            // -group per session, so one session's later notification replaces its
            // own earlier one instead of clobbering a different session's.
            var args = ["-title", title, "-message", body, "-group", group]
            // -execute keeps click-to-reveal working without UNUserNotificationCenter.
            if !transcript.isEmpty {
                args += ["-execute", "/usr/bin/open -R \"\(transcript)\""]
            }
            proc.arguments = args
        } else {
            let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e",
                "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        }
        try? proc.run()
    }

    // Tapping a notification reveals the transcript it is about.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        reveal(transcript: info["transcript"] as? String ?? "")
        completion()
    }

    // LSUIElement apps are never "frontmost" in the usual sense; show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completion:
                                   @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }
}

// MARK: - Data

final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var sessions: [Session] = []
    @Published var budget: Budget?
    @Published var title = "…"
    @Published var notificationsEnabled = true

    private var lastState: [String: String] = [:]
    private var lastBudgetTight = false
    /// The first poll only records state. Without this, launching while sessions are
    /// already cold fires a notification per session for news you did not ask for.
    private var seeded = false
    private var timer: Timer?
    /// CACHEBAR_SCRIPT wins, then the copy build.sh bundled, then the pre-repo
    /// install location.
    private let script: String = {
        if let env = ProcessInfo.processInfo.environment["CACHEBAR_SCRIPT"],
           !env.isEmpty { return env }
        if let bundled = Bundle.main.path(forResource: "ai-cache-bar", ofType: "py") {
            return bundled
        }
        return NSString(string: "~/.claude/scripts/ai-cache-bar.py").expandingTildeInPath
    }()

    func start() {
        Notifier.shared.requestAuthorization()
        refresh()
        // CACHEBAR_TEST_NOTIFICATION=1 fires one notification a few seconds after
        // launch, once authorization has had a chance to resolve.
        if ProcessInfo.processInfo.environment["CACHEBAR_TEST_NOTIFICATION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.sendTestNotification() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let script = self.script
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script, "--json"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let decoder = JSONDecoder()
            var rows: [Session]
            var budget: Budget?
            if let payload = try? decoder.decode(Payload.self, from: data) {
                rows = payload.sessions
                budget = payload.budget
            } else if let bare = try? decoder.decode([Session].self, from: data) {
                rows = bare
            } else {
                return
            }
            DispatchQueue.main.async { self?.apply(rows, budget) }
        }
    }

    private func apply(_ rows: [Session], _ newBudget: Budget?) {
        sessions = rows
        budget = newBudget
        if let top = rows.first(where: { $0.ttl_known }) {
            title = top.state == "cold" ? "❄️ \(hms(top.age))" : "\(top.icon) \(hms(top.left))"
        } else {
            title = "🫥"
        }

        for row in rows where row.ttl_known && row.age < 7200 {
            let was = lastState[row.session] ?? "warm"
            lastState[row.session] = row.state
            guard seeded, was != row.state, notificationsEnabled else { continue }
            if row.state == "expiring" {
                Notifier.shared.post(
                    title: "Cache expiring: \(row.display)",
                    body: "\(hms(row.left)) left on \(kt(row.cached)) cached. Any message refreshes the hour.",
                    transcript: row.path,
                    group: "cachebar-\(row.session)")
            } else if row.state == "cold" {
                Notifier.shared.post(
                    title: "Cache cold: \(row.display)",
                    body: "Next turn rewrites \(kt(row.cached)) at 1.25x instead of reading at 0.1x.",
                    transcript: row.path,
                    group: "cachebar-\(row.session)")
            }
        }
        if let b = newBudget {
            let tight = b.would_exhaust_5h
            if seeded, tight, !lastBudgetTight, notificationsEnabled {
                Notifier.shared.post(
                    title: "Compacting everything would exhaust your 5h limit",
                    body: "\(b.chats) chats ≈ \(String(format: "%.1f", b.compaction_pct_5h))% "
                        + "but only \(b.left_pct_5h.map(String.init) ?? "?")% left. \(b.detail)",
                    group: "cachebar-budget")
            }
            lastBudgetTight = tight
        }
        seeded = true
    }

    /// Verifies delivery end to end, and triggers the authorization prompt on a
    /// first run. Carries a real transcript so tapping it also tests the reveal.
    func sendTestNotification() {
        let target = sessions.first
        Notifier.shared.post(
            title: "CacheBar test notification",
            body: target.map { "Tap to reveal “\($0.display)”." }
                ?? "Delivery works. No sessions right now.",
            transcript: target?.path ?? "")
    }

    var warmCount: Int {
        sessions.filter { $0.ttl_known && ($0.state == "warm" || $0.state == "expiring") }.count
    }
}

// MARK: - Menu

@main
struct CacheBarApp: App {
    @StateObject private var monitor = Monitor.shared

    init() { Monitor.shared.start() }

    var body: some Scene {
        MenuBarExtra {
            Text("Prompt cache · \(monitor.warmCount) warm / \(monitor.sessions.count) recent")
            Divider()
            ForEach(monitor.sessions) { s in
                Button("\(s.icon)  \(s.display)  ·  \(s.detail)") {
                    reveal(transcript: s.path)
                }
            }
            if let b = monitor.budget {
                Divider()
                Text(b.line)
                Text(b.detail)
                if let r = b.reset {
                    Text("\(r.kind ?? "?") limit capping now · resets in \(hms(r.resets_in))")
                }
            }
            Divider()
            Toggle("Notify on expiry", isOn: $monitor.notificationsEnabled)
            Button("Refresh now") { monitor.refresh() }
            Button("Send test notification") { monitor.sendTestNotification() }
            Divider()
            Button("Quit CacheBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Text(monitor.title)
        }
    }
}
