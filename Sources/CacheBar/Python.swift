// Running ai-cache-bar.py, and finding a Python 3 to run it with.
//
// A GUI app gets launchd's minimal PATH, and /usr/bin/python3 can't be run blindly:
// without Apple's Command Line Tools it is a stub that opens their install dialog
// instead of running anything. So the interpreter is looked up off the main thread
// and each candidate vetted with a short run before it is used:
//   1. an explicit setting — `--python`, then CACHEBAR_PYTHON, then Settings. It
//      decides alone: when it doesn't vet, the menu says so rather than quietly
//      running some other Python.
//   2. the Python found last time, if it still vets;
//   3. the active developer directory's (`xcode-select -p`: Xcode or the Command
//      Line Tools), the real binary behind the /usr/bin stub;
//   4. Homebrew, python.org, MacPorts, then mise, asdf and pyenv installs, newest
//      version first.
import Foundation

/// The home the script sees: $HOME, so a test's fake home applies to both halves.
/// (NSHomeDirectory() ignores $HOME.)
let userHome = appEnv["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()

/// The script the app runs: CACHEBAR_SCRIPT wins, then the copy build.sh bundled,
/// then the checkout a `swift build` binary sits in, then the pre-repo install
/// location.
let scriptPath: String = {
    if let env = appEnv["CACHEBAR_SCRIPT"], !env.isEmpty {
        return NSString(string: env).expandingTildeInPath
    }
    if let bundled = Bundle.main.path(forResource: "ai-cache-bar", ofType: "py") {
        return bundled
    }
    // <checkout>/.build/<triple>/<config>/CacheBar
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<4 where dir.path != "/" {
            if dir.lastPathComponent == ".build" {
                let copy = dir.deletingLastPathComponent().appendingPathComponent("ai-cache-bar.py").path
                if FileManager.default.fileExists(atPath: copy) { return copy }
                break
            }
            dir = dir.deletingLastPathComponent()
        }
    }
    return "\(userHome)/.claude/scripts/ai-cache-bar.py"
}()

// MARK: - Running a tool

/// A value shared between the threads of one run.
final class Locked<T> {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    /// A read-modify-write under one lock.
    func update(_ change: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}

struct Ran {
    var status: Int32 = -1
    var stdout = Data()
    var stderr = ""
    var timedOut = false
    /// Ended by a signal (status is then the signal number).
    var signaled = false
    /// The executable could not be started at all.
    var launchError: String?
    var timeout: TimeInterval = 0

    var ok: Bool { failure == nil }

    /// Why it failed, phrased to follow the tool's name; nil when it worked.
    var failure: String? {
        if let e = launchError { return "could not start: \(e)" }
        if timedOut { return "timed out after \(Int(timeout))s" }
        if signaled { return "was killed by signal \(status)" }
        if status != 0 { return "exited \(status)" + (errorLine.map { ": \($0)" } ?? "") }
        return nil
    }

    /// The stderr line worth showing: the first, or for a Python traceback (whose
    /// first line says nothing) the exception at its end.
    var errorLine: String? {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let line = first.hasPrefix("Traceback (most recent call last)") ? lines[lines.count - 1] : first
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}

/// The tools running now, so quitting CacheBar ends them too: a `--calibrate` scan
/// (up to 600 s) would otherwise outlive the app.
let runningTools = Locked(Set<Process>())

/// Ends every running tool (quit, SIGTERM).
func terminateRunningTools() {
    for proc in runningTools.value where proc.isRunning { proc.terminate() }
}

/// Runs a tool to completion, or kills it after `timeout` (SIGTERM, then SIGKILL).
/// stdout and stderr drain on their own threads so neither pipe can fill and stall
/// the child; stdin is /dev/null.
func runTool(_ path: String, _ args: [String], env: [String: String] = appEnv,
             timeout: TimeInterval) -> Ran {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    proc.environment = env
    proc.standardInput = FileHandle.nullDevice
    let outPipe = Pipe(), errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    let exited = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in exited.signal() }
    do { try proc.run() } catch {
        return Ran(launchError: error.localizedDescription, timeout: timeout)
    }
    runningTools.update { _ = $0.insert(proc) }
    defer { runningTools.update { _ = $0.remove(proc) } }

    let out = Locked(Data()), err = Locked(Data())
    let drained = DispatchGroup()
    for (pipe, box) in [(outPipe, out), (errPipe, err)] {
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            box.value = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
    }
    let killed = Locked(false)
    let killer = DispatchWorkItem {
        guard proc.isRunning else { return }
        killed.value = true
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    exited.wait()
    killer.cancel()
    // A grandchild still holding the pipes open must not hang the caller.
    _ = drained.wait(timeout: .now() + 2)
    return Ran(status: proc.terminationStatus, stdout: out.value,
               stderr: String(decoding: err.value, as: UTF8.self),
               timedOut: killed.value, signaled: proc.terminationReason == .uncaughtSignal,
               timeout: timeout)
}

// MARK: - Finding Python

/// A vetted interpreter, and where it came from.
struct Python: Equatable {
    let path: String
    let version: String
    /// "--python", "CACHEBAR_PYTHON", "Settings" or "detected".
    let source: String

    var origin: String { originPhrase(source) }
}

/// "set in Settings", "set by --python", "detected".
func originPhrase(_ source: String) -> String {
    switch source {
    case "detected": return "detected"
    case "Settings": return "set in Settings"
    default: return "set by \(source)"
    }
}

enum PythonLookup: Equatable {
    case locating
    case found(Python)
    /// No explicit setting, and nothing usable installed.
    case none
    /// The explicit setting failed vetting; it is not second-guessed.
    case unusable(path: String, source: String, why: String)
}

/// UserDefaults key for the Python detected last time, tried first next time.
let rememberedPythonKey = "rememberedPython"

enum Pythons {
    /// Long enough for a first launch that Gatekeeper scans; a working Python
    /// answers in well under a second.
    static let vetTimeout: TimeInterval = 10

    /// The explicit setting and who made it: an argument wins (Arguments.swift), then
    /// the environment (tests), then the app's defaults, which Settings writes (and
    /// `defaults write com.michieltimmerman.cachebar CACHEBAR_PYTHON <path>` can too).
    static func explicit() -> (path: String, source: String)? {
        let key = "CACHEBAR_PYTHON"
        if let v = overrides.value(forSettingKey: key) { return (v, Overrides.flag(forSettingKey: key)!) }
        if let v = appEnv[key], !v.isEmpty { return (NSString(string: v).expandingTildeInPath, key) }
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty {
            return (NSString(string: v).expandingTildeInPath, "Settings")
        }
        return nil
    }

    static func resolve(remembered: String?) -> PythonLookup {
        if let set = explicit() {
            switch vet(set.path) {
            case .success(let version): return .found(Python(path: set.path, version: version, source: set.source))
            case .failure(let e): return .unusable(path: set.path, source: set.source, why: e.why)
            }
        }
        let fm = FileManager.default
        var tried = Set<String>()
        for path in [remembered].compactMap({ $0 }) + candidates()
        where tried.insert(path).inserted && fm.isExecutableFile(atPath: path) {
            switch vet(path) {
            case .success(let version): return .found(Python(path: path, version: version, source: "detected"))
            case .failure(let e): debug("vet: \(path) — \(e.why)")
            }
        }
        return .none
    }

    struct Unusable: Error { let why: String }

    /// Runs it once: it has to start, and be Python 3.6 or newer. Returns the version.
    static func vet(_ path: String) -> Result<String, Unusable> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .failure(Unusable(why: "\(path) does not exist")) }
        guard fm.isExecutableFile(atPath: path) else { return .failure(Unusable(why: "\(path) is not executable")) }
        // Never wake the stub's install dialog by running it; say what it needs.
        if path.hasPrefix("/usr/bin/python"), developerDir() == nil {
            return .failure(Unusable(why: "it needs Apple's Command Line Tools (xcode-select --install)"))
        }
        // Valid Python 2 as well, so an old interpreter reports its version.
        let probe = "import sys; sys.stdout.write('%d.%d.%d' % tuple(sys.version_info[:3])); "
            + "sys.exit(0 if sys.version_info >= (3, 6) else 3)"
        let r = runTool(path, ["-c", probe], timeout: vetTimeout)
        let version = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 3, !version.isEmpty, !r.timedOut, !r.signaled {
            return .failure(Unusable(why: "Python \(version) is older than 3.6"))
        }
        if let why = r.failure { return .failure(Unusable(why: "it \(why)")) }
        guard version.hasPrefix("3.") else {
            return .failure(Unusable(why: "it doesn't look like Python (printed \"\(version.prefix(40))\")"))
        }
        return .success(version)
    }

    /// The active developer directory, when Xcode or the Command Line Tools are
    /// installed. `xcode-select -p` only prints; it never opens a dialog.
    static func developerDir() -> String? {
        let r = runTool("/usr/bin/xcode-select", ["-p"], timeout: 5)
        let dir = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !dir.isEmpty && FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// Everywhere a python3 is usually installed, in the order they are tried.
    static func candidates() -> [String] {
        let fm = FileManager.default
        /// Version folders ("3.12.4", "3.13") in `dir`, newest first.
        func versions(in dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasPrefix("3.") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        }
        var list: [String] = []
        if let dev = developerDir() { list.append("\(dev)/usr/bin/python3") }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            list.append("\(dir)/python3")
            let pinned = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.range(of: #"^python3\.\d+$"#, options: .regularExpression) != nil }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            list += pinned.map { "\(dir)/\($0)" }
        }
        let frameworks = "/Library/Frameworks/Python.framework/Versions"
        list += versions(in: frameworks).map { "\(frameworks)/\($0)/bin/python3" }
        list.append("/opt/local/bin/python3")
        let mise = appEnv["MISE_DATA_DIR"] ?? "\(userHome)/.local/share/mise"
        for dir in ["\(mise)/installs/python", "\(userHome)/.asdf/installs/python", "\(userHome)/.pyenv/versions"] {
            list += versions(in: dir).map { "\(dir)/\($0)/bin/python3" }
        }
        return list
    }
}
