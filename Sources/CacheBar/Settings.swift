// The Settings window. A plain window rather than SwiftUI's Settings scene: a
// menu-bar-only app has no app menu to open that from, and since macOS 14 it can't
// be opened programmatically.
//
// Everything here is saved in the app's defaults, which is what an app started by
// Finder or launch at login can read. The numbers reach ai-cache-bar.py as its
// AI_CACHE_* environment variables. A command-line argument or an environment
// variable still wins for its run; the control then shows that value, disabled,
// with a note saying what set it.
import AppKit
import SwiftUI

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController:
                NSHostingController(rootView: SettingsView(monitor: .shared)))
            w.title = "CacheBar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        debug("settings window: visible \(window?.isVisible ?? false)")
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: effective(overrides.notifications, $monitor.prefs.notify))
                    .disabled(overrides.notifications != nil)
                ArgumentNote(flag: "--notifications", active: overrides.notifications != nil)
                KnobPicker(title: "Warn before a chat goes cold", knob: monitor.prefs.warn,
                           choices: [2, 5, 10, 15, 20, 30], saved: $monitor.prefs.warnMinutes)
            } header: {
                Text("Notifications")
            } footer: {
                Text("A banner when a chat is about to go cold, when it has, when a turn just paid to "
                     + "rewrite a cold cache, and when compacting everything would exhaust the 5-hour limit.")
                    .foregroundStyle(.secondary)
            }

            Section("Menu") {
                KnobPicker(title: "Rows in the menu", knob: monitor.prefs.rows,
                           choices: [5, 10, 15, 20, 30], saved: $monitor.prefs.maxRows)
                KnobPicker(title: "Look back", knob: monitor.prefs.lookback,
                           choices: [1, 2, 4, 8, 12, 24], saved: $monitor.prefs.lookbackHours)
            }

            Section {
                LabeledContent("In use") { pythonStatus }
                PathOverride(title: "Override", key: "CACHEBAR_PYTHON") { monitor.pythonSettingChanged() }
                Button("Detect again") { monitor.pythonSettingChanged() }
            } header: {
                Text("Python")
            } footer: {
                Text("CacheBar reads your chats with its bundled script, which needs Python 3.6 or newer. "
                     + "Automatic finds the one in Apple's Command Line Tools (xcode-select --install), "
                     + "Homebrew, python.org, MacPorts, mise, asdf or pyenv. An override is used as is.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { monitor.launchAtLogin },
                    set: { monitor.setLaunchAtLogin($0) }))
                if let note = monitor.launchAtLoginNote {
                    Text(note).foregroundStyle(.secondary)
                }
            } footer: {
                HStack {
                    Text("CacheBar \(appVersion)")
                    Spacer()
                    Link("github.com/michieltimmerman/cachebar",
                         destination: URL(string: "https://github.com/michieltimmerman/cachebar")!)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls and has no ideal height of its own; without a
        // fixed size the window shrinks to nothing.
        .frame(width: 540, height: 620)
    }

    @ViewBuilder private var pythonStatus: some View {
        switch monitor.python {
        case .locating:
            Text("Looking…").foregroundStyle(.secondary)
        case .found(let py):
            VStack(alignment: .trailing) {
                Text(py.path).lineLimit(1).truncationMode(.middle)
                Text("Python \(py.version) · \(py.origin)").foregroundStyle(.secondary)
            }
        case .none:
            Text("No Python 3 found").foregroundStyle(.red)
        case .unusable(let path, _, let why):
            VStack(alignment: .trailing) {
                Text(path).lineLimit(1).truncationMode(.middle)
                Text("Not usable: \(why)").foregroundStyle(.red)
            }
        }
    }
}

/// A control showing a command-line override shows the overriding value (and is
/// disabled); otherwise it edits the saved setting.
private func effective<T>(_ override: T?, _ saved: Binding<T>) -> Binding<T> {
    Binding(get: { override ?? saved.wrappedValue }, set: { saved.wrappedValue = $0 })
}

private struct ArgumentNote: View {
    let flag: String
    let active: Bool

    var body: some View {
        if active {
            Text("Set by \(flag) for this run.").foregroundStyle(.secondary)
        }
    }
}

/// One number setting: a picker over common values, or — when an argument or the
/// environment fixes it for this run — that value, with a note saying which.
/// Picking the script's default clears the setting.
private struct KnobPicker: View {
    let title: String
    let knob: Knob
    let choices: [Int]
    @Binding var saved: Int?

    var body: some View {
        if let by = knob.fixedBy {
            LabeledContent(title, value: knob.text)
            Text(knob.argument != nil ? "Set by \(by) for this run." : "Set by the \(by) environment variable.")
                .foregroundStyle(.secondary)
        } else {
            Picker(title, selection: Binding(
                get: { saved ?? knob.standard },
                set: { saved = $0 == knob.standard ? nil : $0 })) {
                ForEach(values, id: \.self) { Text(knob.label($0)).tag($0) }
            }
        }
    }

    /// The choices, plus a saved value outside them (`defaults write`).
    private var values: [Int] {
        let current = saved ?? knob.standard
        return choices.contains(current) ? choices : (choices + [current]).sorted()
    }
}

/// One path setting: Automatic, or a file picked with Choose….
private struct PathOverride: View {
    let title: String
    let key: String
    let changed: () -> Void
    @AppStorage private var value: String

    init(title: String, key: String, changed: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.changed = changed
        _value = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(value.isEmpty ? "Automatic" : value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                Button("Choose…") {
                    if let path = choose() {
                        value = path
                        changed()
                    }
                }
                if !value.isEmpty {
                    Button("Clear") {
                        value = ""
                        changed()
                    }
                }
            }
        }
        if overrides.value(forSettingKey: key) != nil, let flag = Overrides.flag(forSettingKey: key) {
            Text("Set by \(flag) for this run.").foregroundStyle(.secondary)
        } else if let env = appEnv[key], !env.isEmpty {
            Text("The \(key) environment variable overrides this.").foregroundStyle(.secondary)
        }
    }

    private func choose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose python3"
        panel.message = "Pick a python3 executable, e.g. /opt/homebrew/bin/python3 (⇧⌘G types a path)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // Keep /opt/homebrew/bin/python3 as picked: its resolved Cellar path breaks
        // on the next brew upgrade.
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
