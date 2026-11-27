// Command-line arguments. Every setting in the Settings window can also be given
// for one run — `open -a CacheBar --args --warn-minutes 5`, or the binary itself —
// and an argument wins over the environment, which wins over Settings. Arguments
// are never saved: for a lasting change, use Settings.
import Foundation

/// Settings given on the command line; nil means "not given".
struct Overrides {
    var python: String?
    var notifications: Bool?
    var checkUpdates: Bool?
    var warnMinutes: Int?
    var maxRows: Int?
    var lookbackHours: Int?

    /// The path settings, by their `setting()` key.
    func value(forSettingKey key: String) -> String? {
        key == "CACHEBAR_PYTHON" ? python : nil
    }

    /// The flag that set a `setting()` key, for "set by --python" notes.
    static func flag(forSettingKey key: String) -> String? {
        ["CACHEBAR_PYTHON": "--python"][key]
    }
}

struct Arguments {
    enum Command: Equatable {
        case run, help, version, status, compat
    }

    var command = Command.run
    var overrides = Overrides()

    struct Invalid: Error { let message: String }

    static let options: [(flag: String, value: String, help: String)] = [
        ("--python", "PATH", "python3 to run ai-cache-bar.py with"),
        ("--notifications", "on|off", "show notifications"),
        ("--check-updates", "on|off", "look for a newer CacheBar once a day"),
        ("--warn-minutes", "N", "warn N minutes before a chat goes cold"),
        ("--max-rows", "N", "chats listed in the menu"),
        ("--lookback-hours", "N", "list chats active in the last N hours"),
    ]

    static let usage: String = {
        let width = options.map { $0.flag.count + $0.value.count + 1 }.max() ?? 0
        let lines = options.map { o -> String in
            let left = "\(o.flag) \(o.value)"
            return "  \(left)\(String(repeating: " ", count: width - left.count + 2))\(o.help)"
        }
        return """
        Usage: CacheBar [options]
               CacheBar --status | --compat | --version | --help

        Settings for this run (they win over the environment and the Settings window,
        and are not saved):
        \(lines.joined(separator: "\n"))

        Commands:
          --status   the Python CacheBar would use, then ai-cache-bar.py --text
          --compat   whether your chats' files still have what CacheBar reads
                     (ai-cache-bar.py --compat; exit 1 on a problem)
          --version  print the version
          --help     this text

        Environment: CACHEBAR_PYTHON, CACHEBAR_SCRIPT and the script's AI_CACHE_*
        variables (README.md → Configuration).
        """
    }()

    /// Parses `CommandLine.arguments` (the executable path first). Cocoa's own
    /// `-Key value` pairs are skipped.
    static func parse(_ argv: [String]) throws -> Arguments {
        var a = Arguments()
        var rest = Array(argv.dropFirst())
        while !rest.isEmpty {
            var arg = rest.removeFirst()
            if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg != "-h" {
                if let next = rest.first, !next.hasPrefix("-") { rest.removeFirst() }
                continue
            }
            var inline: String?
            if let eq = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            func value() throws -> String {
                if let inline { return inline }
                guard let v = rest.first, !v.hasPrefix("--") else {
                    throw Invalid(message: "\(arg) needs a value")
                }
                rest.removeFirst()
                return v
            }
            switch arg {
            case "--help", "-h": a.command = .help
            case "--version": a.command = .version
            case "--status": a.command = .status
            case "--compat": a.command = .compat
            case "--python": a.overrides.python = try path(value(), arg)
            case "--notifications": a.overrides.notifications = try bool(value(), arg)
            case "--check-updates": a.overrides.checkUpdates = try bool(value(), arg)
            case "--warn-minutes": a.overrides.warnMinutes = try count(value(), arg)
            case "--max-rows": a.overrides.maxRows = try count(value(), arg)
            case "--lookback-hours": a.overrides.lookbackHours = try count(value(), arg)
            default: throw Invalid(message: "unknown option \(arg)")
            }
        }
        return a
    }

    private static func path(_ v: String, _ flag: String) throws -> String {
        let expanded = NSString(string: v).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw Invalid(message: "\(flag): \(v) does not exist")
        }
        return expanded
    }

    private static func bool(_ v: String, _ flag: String) throws -> Bool {
        switch v.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default: throw Invalid(message: "\(flag) takes on or off, not \(v)")
        }
    }

    private static func count(_ v: String, _ flag: String) throws -> Int {
        guard let n = Int(v), n > 0 else {
            throw Invalid(message: "\(flag) takes a whole number above zero, not \(v)")
        }
        return n
    }
}

/// This run's arguments; parsed first thing at launch.
var launchArguments = Arguments()
var overrides: Overrides { launchArguments.overrides }
