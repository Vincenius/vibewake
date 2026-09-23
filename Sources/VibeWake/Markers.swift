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
    var cwd: String?
    var startedAt: Double
    var touchedAt: Double
    var label: String?
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent(".vibewake")
    static let active = root.appendingPathComponent("active")
    static let state = root.appendingPathComponent("state")
    /// Present while VibeWake has set `pmset disablesleep 1`, so we only undo what we did.
    static let disableSleepOwned = state.appendingPathComponent("disablesleep-owned")

    static func ensure() {
        for dir in [active, state] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
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

    /// Create or refresh a marker, preserving its original start time.
    static func upsert(_ url: URL, agent: String, session: String, kind: String, pid: Int32, cwd: String?, label: String? = nil) {
        Paths.ensure()
        let now = Date().timeIntervalSince1970
        let existing = read(url)
        let marker = Marker(agent: agent, session: session, kind: kind, pid: pid,
                            cwd: cwd ?? existing?.cwd,
                            startedAt: existing?.startedAt ?? now, touchedAt: now,
                            label: label ?? existing?.label)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        let tmp = url.appendingPathExtension("tmp\(getpid())")
        do {
            try data.write(to: tmp)
            _ = rename(tmp.path, url.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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
