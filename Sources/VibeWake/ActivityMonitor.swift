import Foundation

/// One thing currently keeping the Mac awake, as shown in the menu.
struct ActiveItem {
    /// Stable identity across evaluations, used to log start/finish.
    let id: String
    let pid: Int32
    let agent: String
    let project: String?
    let since: Double
    let subagents: Int
    let backgroundShells: Int
    let detail: String?
}

/// Decides whether any AI agent is doing work, from marker files + the process table.
final class ActivityMonitor {
    struct Config {
        /// A turn/subagent marker without heartbeat for this long is considered stale
        /// (e.g. a turn interrupted with Esc never fires Stop) unless a shell is running.
        var staleAfter: Double = 20 * 60
        /// Shell children younger than this are ignored (hooks, statusline scripts).
        var minShellAge: Double = 5
        /// Agents detected purely by process (no hooks installed): binary names.
        var knownAgentBinaries: Set<String> = ["claude", "codex", "pi"]
        /// Of those, which may be detected by CPU usage alone.
        var cpuHeuristicBinaries: Set<String> = ["codex", "opencode", "gemini", "aider"]
        var cpuThreshold: Double = 0.03 // 3% of one core
    }

    var config = Config()
    private var lastCpu: [Int32: (cpu: Double, at: Double)] = [:]

    func evaluate() -> [ActiveItem] {
        let now = Date().timeIntervalSince1970
        let table = ProcessTree.snapshot()
        let markers = MarkerStore.all()

        // Group markers by agent session.
        struct Group { var agent = ""; var cwd: String?; var pid: Int32 = 0
            var turn: Marker?; var subs: [Marker] = []; var hasPresence = false; var transcript: String?
            var awaitingInput = false }
        var groups: [String: Group] = [:]

        for (url, m) in markers {
            guard ProcessTree.isAlive(m, in: table) else {
                MarkerStore.remove(url) // agent process is gone → stale marker
                if m.kind != "session" {
                    Log.write("session", "\(m.agent) process \(m.pid) exited without finishing its \(m.kind) — marker removed")
                }
                continue
            }
            let key = "\(m.agent)-\(m.session)"
            var g = groups[key] ?? Group()
            g.agent = m.agent; g.pid = m.pid
            if g.cwd == nil { g.cwd = m.cwd }
            switch m.kind {
            case "turn": g.turn = m
            case "subagent": g.subs.append(m)
            default: g.hasPresence = true; g.transcript = m.transcript; g.awaitingInput = m.awaitingInputAt != nil
            }
            groups[key] = g
        }

        var items: [ActiveItem] = []
        var coveredPids = Set<Int32>()

        for (key, g) in groups {
            coveredPids.insert(g.pid)
            let shellProcs = ProcessTree.longRunningShellChildren(of: g.pid, in: table, minAge: config.minShellAge)
            let shells = shellProcs.count
            let fresh: (Marker) -> Bool = { now - $0.touchedAt < self.config.staleAfter || shells > 0 }
            // A turn interrupted with Esc never fires Stop; the transcript says so.
            // A turn waiting for a permission answer does no work until the user is back.
            let turnActive = g.turn.map { fresh($0) && !g.awaitingInput
                && !SessionInbox.lastTurnInterrupted(transcript: g.transcript, after: $0.startedAt) } ?? false
            let subs = g.subs.filter(fresh)

            guard turnActive || !subs.isEmpty || shells > 0 else { continue }
            let since = (([g.turn].compactMap { $0 } + subs).map(\.startedAt) + shellProcs.map(\.startTime)).min() ?? now
            let detail: String? = turnActive ? nil : (subs.isEmpty ? "background task" : "subagents")
            items.append(ActiveItem(id: key, pid: g.pid, agent: g.agent, project: g.cwd.map { ($0 as NSString).lastPathComponent },
                                    since: since, subagents: subs.count, backgroundShells: shells, detail: detail))
        }

        // Agents without hooks (or whose hooks are not installed): process heuristics.
        var seenCpu = Set<Int32>()
        for p in table.values where config.knownAgentBinaries.contains(p.name) || config.cpuHeuristicBinaries.contains(p.name) {
            guard !coveredPids.contains(p.pid) else { continue }
            let shellProcs = ProcessTree.longRunningShellChildren(of: p.pid, in: table, minAge: config.minShellAge)
            let shells = shellProcs.count
            var busy = shells > 0
            var detail = "background task"
            if config.cpuHeuristicBinaries.contains(p.name), let cpu = ProcessTree.cpuSeconds(p.pid) {
                seenCpu.insert(p.pid)
                if let last = lastCpu[p.pid], now > last.at {
                    let usage = (cpu - last.cpu) / (now - last.at)
                    if usage > config.cpuThreshold { busy = true; detail = "working" }
                }
                lastCpu[p.pid] = (cpu, now)
            }
            if busy {
                items.append(ActiveItem(id: "\(p.name)-pid\(p.pid)", pid: p.pid, agent: p.name, project: nil, since: shellProcs.map(\.startTime).min() ?? now,
                                        subagents: 0, backgroundShells: shells, detail: detail))
            }
        }
        lastCpu = lastCpu.filter { seenCpu.contains($0.key) }

        return items.sorted { $0.since < $1.since }
    }
}
