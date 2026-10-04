import Foundation

/// A marker file in ~/.vibewake/active/ written by agent hooks / extensions.
///
/// kind:
///  - "turn":     the main agent is working on a prompt
///  - "subagent": a subagent (possibly running in the background) is working
///  - "session":  the agent session exists (not activity by itself; lets the
///                monitor attribute background shells to a known agent)
struct Marker: Codable {
    var agent: String
    var session: String
    var kind: String
    var pid: Int32
    /// Start time of `pid`, so a reused pid isn't mistaken for the agent (nil for pi markers).
    var pidStart: Double?
    var cwd: String?
    var startedAt: Double
    var touchedAt: Double
    var label: String?
    /// Turn and subagent markers: Bash calls started (PreToolUse) and not yet finished. A shell that runs
    /// during one is a build or tests; without one it is background work. nil: written before this was tracked.
    var openTools: [String]?
    // Session markers only (Claude Code): how to reach and describe the chat.
    /// Inbox socket of the session (CLAUDE_CODE_MESSAGING_SOCKET) and its token.
    var socket: String?
    var token: String?
    var transcript: String?
    /// Custom title reported by SessionStart; the AI title is read from the transcript.
    var title: String?
    /// Set by StopFailure(rate_limit): when the usage limit resets (epoch seconds).
    var limitResetAt: Double?
    /// Last time a turn ended normally (Stop).
    var lastStopAt: Double?
    /// Set by a Notification hook (permission prompt, question): the turn waits for the user.
    /// Cleared by the main agent's next sign of life.
    var awaitingInputAt: Double?
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent(".vibewake")
    static let active = root.appendingPathComponent("active")
    static let state = root.appendingPathComponent("state")
    static let queue = root.appendingPathComponent("queue")
    /// Present while VibeWake has set `pmset disablesleep 1`, so we only undo what we did.
    static let disableSleepOwned = state.appendingPathComponent("disablesleep-owned")
    /// The `pmset schedule wake` date VibeWake set, so only that one is cancelled.
    static let scheduledWake = state.appendingPathComponent("scheduled-wake")

    static func ensure() {
        for dir in [active, state, queue] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// An exclusive lock between processes (app, hooks, CLI) for read-modify-write of shared files.
enum FileLock {
    static func with<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        Paths.ensure()
        let fd = open(Paths.state.appendingPathComponent(name).path, O_RDWR | O_CREAT, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } } // closing releases the lock
        return try body()
    }
}

enum MarkerStore {
    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(cleaned.prefix(80))
    }

    static func url(agent: String, session: String, kind: String, id: String? = nil) -> URL {
        var name = "\(sanitize(agent))-\(sanitize(session)).\(kind)"
        if let id { name += "-\(sanitize(id))" }
        return Paths.active.appendingPathComponent(name + ".json")
    }

    static func read(_ url: URL) -> Marker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Create or refresh a marker, preserving its original start time and extra fields.
    static func upsert(_ url: URL, agent: String, session: String, kind: String, pid: Int32, cwd: String?, label: String? = nil,
                       update: ((inout Marker) -> Void)? = nil) {
        FileLock.with("markers.lock") {
            let now = Date().timeIntervalSince1970
            var marker = read(url) ?? Marker(agent: agent, session: session, kind: kind, pid: pid, cwd: nil, startedAt: now, touchedAt: now)
            if marker.pid != pid || marker.pidStart == nil { marker.pidStart = ProcessTree.startTime(of: pid) }
            marker.pid = pid
            marker.touchedAt = now
            if let cwd { marker.cwd = cwd }
            if let label { marker.label = label }
            update?(&marker)
            write(marker, to: url)
        }
    }

    /// Change fields of an existing marker without refreshing its heartbeat.
    static func modify(_ url: URL, _ update: (inout Marker) -> Void) {
        FileLock.with("markers.lock") {
            guard var marker = read(url) else { return }
            update(&marker)
            write(marker, to: url)
        }
    }

    /// Atomic write, readable only by the user (session markers hold the inbox token).
    static func writeAtomically(_ data: Data, to url: URL) {
        let tmp = url.appendingPathExtension("tmp\(getpid())")
        if FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
        }
    }

    private static func write(_ marker: Marker, to url: URL) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        writeAtomically(data, to: url)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Subagent markers of one session, with the subagent id their file is named after.
    static func subagents(agent: String, session: String) -> [(id: String, url: URL)] {
        let prefix = "\(sanitize(agent))-\(sanitize(session)).sub-"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.active.path)) ?? []
        return files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.map {
            (String($0.dropFirst(prefix.count).dropLast(5)), Paths.active.appendingPathComponent($0))
        }
    }

    /// Remove every marker belonging to one agent session.
    static func removeSession(agent: String, session: String) {
        let prefix = "\(sanitize(agent))-\(sanitize(session))."
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.active.path)) ?? []
        for f in files where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: Paths.active.appendingPathComponent(f))
        }
    }

    static func all() -> [(URL, Marker)] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.active.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { f in
            let u = Paths.active.appendingPathComponent(f)
            return read(u).map { (u, $0) }
        }
    }
}
