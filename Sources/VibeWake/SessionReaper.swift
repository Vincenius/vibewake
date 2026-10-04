import Foundation

/// Closes what a Claude Code chat left running (dev servers, watchers, background tasks) once the chat
/// has ended: closed, cleared with /clear, or its process gone.
///
/// Two ways to tell what a chat started:
/// - Each Bash shell of Claude Code leads a process group of its own, and what it starts (also with `&`
///   or `nohup`) stays in that group after the shell or the agent is gone. The groups are noted while the chat runs.
/// - Claude Code puts CLAUDE_PID and CLAUDE_CODE_SESSION_ID into the environment of its shells, and
///   everything started from there inherits them: this finds what left its group (daemons).
final class SessionReaper {
    private struct Chat {
        let session: String; let pid: Int32; let pidStart: Double?; let label: String
        /// Process groups of the shells it started.
        var groups: Set<Int32>
    }

    /// Chats seen at the last update, by "<id>@<pid>" (a resumed chat runs in a new process).
    private var live: [String: Chat] = [:]
    private let queue = DispatchQueue(label: "com.vibewake.reaper", qos: .utility)
    /// Between SIGTERM and SIGKILL.
    private static let killAfter: Double = 5
    /// A second look once an exiting agent is gone: what it left behind is orphaned by then.
    private static let recheckAfter: Double = 15

    /// Call after every autopilot tick.
    func update(_ sessions: [AgentSession], enabled: Bool) {
        let table = ProcessTree.snapshot()
        let existing = Set(table.values.map(\.pgid))
        var current: [String: Chat] = [:]
        for s in sessions where s.agent == "claude" {
            let key = "\(s.id)@\(s.pid)"
            // A group with no process left is forgotten: its number may come back for someone else.
            var groups = live[key]?.groups.filter { existing.contains($0) } ?? Set()
            for p in table.values where p.ppid == s.pid && p.pgid == p.pid && ProcessTree.shells.contains(p.name) {
                groups.insert(p.pgid)
            }
            current[key] = Chat(session: s.session, pid: s.pid, pidStart: s.presence?.pidStart ?? s.turn?.pidStart,
                                label: "\(s.project ?? s.agent) · \(s.title.map { "“\($0)”" } ?? String(s.session.prefix(8)))",
                                groups: groups)
        }
        let ended = live.filter { current[$0.key] == nil }.map(\.value)
        live = current
        guard enabled, !ended.isEmpty else { return }

        let markers = MarkerStore.all().map(\.1)
        let running = Set(current.values.map(\.pid))
        let at = Date().timeIntervalSince1970
        for chat in ended {
            // Really over (SessionEnd removed its markers, or its process is gone), not a marker missed once.
            let alive = ProcessTree.isAlive(chat.pid, start: chat.pidStart, in: table)
            guard !alive || !markers.contains(where: { $0.session == chat.session && $0.pid == chat.pid }) else { continue }
            queue.async { Self.reap(chat, endedAt: at, running: running) }
            queue.asyncAfter(deadline: .now() + Self.recheckAfter) { Self.reap(chat, endedAt: at, running: running) }
        }
    }

    private static func reap(_ chat: Chat, endedAt: Double, running: Set<Int32>) {
        let victims = leftovers(of: chat, endedAt: endedAt, running: running, in: ProcessTree.snapshot())
        guard !victims.isEmpty else { return }
        for p in victims { kill(p.pid, SIGTERM) }
        let names = Dictionary(grouping: victims, by: \.name)
            .map { $0.value.count > 1 ? "\($0.key) ×\($0.value.count)" : $0.key }.sorted()
        Log.write("session", "\(chat.label) ended — closed \(victims.count) process\(victims.count == 1 ? "" : "es") it left running: "
                  + names.joined(separator: ", "))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killAfter) {
            let table = ProcessTree.snapshot()
            for p in victims where table[p.pid].map({ abs($0.startTime - p.startTime) < 0.5 }) == true { kill(p.pid, SIGKILL) }
        }
    }

    /// What the ended chat started that still runs. Never this app, another running chat,
    /// or the editor or terminal such a chat lives in.
    private static func leftovers(of chat: Chat, endedAt: Double, running: Set<Int32>, in table: [Int32: ProcInfo]) -> [ProcInfo] {
        var children: [Int32: [Int32]] = [:]
        for p in table.values where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }
        func subtree(_ pid: Int32) -> Set<Int32> {
            var seen: Set<Int32> = [pid], stack = [pid]
            while let p = stack.popLast() {
                for c in children[p] ?? [] where seen.insert(c).inserted { stack.append(c) }
            }
            return seen
        }
        func ancestors(_ pid: Int32) -> [Int32] {
            var out: [Int32] = [], p = table[pid]?.ppid ?? 1
            while p > 1, out.count < 64, let info = table[p] { out.append(p); p = info.ppid }
            return out
        }

        let me = getpid()
        var keep = subtree(me).union(ancestors(me))
        let alive = ProcessTree.isAlive(chat.pid, start: chat.pidStart, in: table)
        let own = alive ? subtree(chat.pid) : []
        for agent in running where agent != chat.pid && table[agent] != nil {
            // Another chat, and the app or terminal it runs in (except this chat, if it lives there too).
            let up = ancestors(agent)
            keep.formUnion(subtree(up.last ?? agent).subtracting(own))
            keep.formUnion(up)
            keep.formUnion(subtree(agent))
        }

        // Its shells' process groups, and whatever their members started.
        var tasks = Set<Int32>()
        for p in table.values where chat.groups.contains(p.pgid) { tasks.formUnion(subtree(p.pid)) }

        let agentStart = (chat.pidStart ?? 0) - 1
        return table.values.filter { p in
            guard p.pid > 1, p.pid != chat.pid, !keep.contains(p.pid) else { return false }
            if tasks.contains(p.pid) { return true }
            // The agent's own helpers (MCP servers, …) while it keeps running.
            if own.contains(p.pid) { return false }
            // Started from one of its shells, but left the group.
            guard p.startTime >= agentStart, p.startTime < endedAt,
                  let env = ProcessTree.environment(of: p.pid), env["CLAUDE_PID"] == String(chat.pid) else { return false }
            // A process that hosts the next chat (/clear) only gives up what this one started.
            return !alive || env["CLAUDE_CODE_SESSION_ID"] == chat.session
        }
    }
}
