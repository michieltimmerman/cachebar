// Refresh when a chat writes: an FSEvents watch on the folders the script reads
// (~/.claude/projects, ~/.codex/sessions) polls as soon as a transcript changes,
// so a new turn resets its countdown at once instead of up to 15 s later. Time
// still moves chats from warm to expiring to cold with nothing written, so the
// 15 s poll stays; this only adds polls. Subagent transcripts are ignored: they
// are not chat rows.
import CoreServices
import Foundation

final class ChatWatcher {
    private var stream: FSEventStreamRef?
    private(set) var watching: [String] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// The folders to watch: those of them that exist now.
    static var folders: [String] {
        ["\(userHome)/.claude/projects", "\(userHome)/.codex/sessions"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// (Re)starts the watch when the set of existing folders changed (a first
    /// Claude Code or Codex run creates its folder while CacheBar runs).
    func update() {
        let want = Self.folders
        guard want != watching else { return }
        stop()
        watching = want
        guard !want.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<ChatWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.changed(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, want as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.3, flags) else {
            debug("watch: can't watch \(want.joined(separator: ", "))")
            return
        }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        debug("watch: \(want.joined(separator: ", "))")
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        watching = []
    }

    private func changed(_ paths: [String]) {
        let chats = paths.filter { $0.hasSuffix(".jsonl") && !$0.contains("/subagents/") }
        guard !chats.isEmpty else { return }
        debug("watch: \(chats.count) transcript\(chats.count == 1 ? "" : "s") changed")
        onChange()
    }
}
