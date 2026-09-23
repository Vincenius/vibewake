import Foundation

/// `VibeWake hook <agent>` — invoked by agent hooks (Claude Code, Codex).
/// Reads the hook JSON from stdin, updates marker files, always exits 0 quickly.
enum HookCommand {
    static func run(agent: String) -> Never {
        let data = readStdin()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let event = json["hook_event_name"] as? String ?? ""
        let session = json["session_id"] as? String ?? "unknown"
        let cwd = json["cwd"] as? String
        let agentId = json["agent_id"] as? String
        let agentType = json["agent_type"] as? String
        let pid = agentPid()

        let turn = MarkerStore.url(agent: agent, session: session, kind: "turn")
        let presence = MarkerStore.url(agent: agent, session: session, kind: "session")
        func sub(_ id: String) -> URL { MarkerStore.url(agent: agent, session: session, kind: "sub", id: id) }

        let project = cwd.map { ($0 as NSString).lastPathComponent } ?? "?"
        let who = "\(project) · \(session.prefix(8))"
        func log(_ msg: String) { Log.write(agent, "\(who)  \(msg)") }
        func duration(of url: URL) -> String {
            guard let m = MarkerStore.read(url) else { return "" }
            return " after " + formatDuration(Date().timeIntervalSince1970 - m.startedAt)
        }

        func touchPresence() {
            if !FileManager.default.fileExists(atPath: presence.path) {
                MarkerStore.upsert(presence, agent: agent, session: session, kind: "session", pid: pid, cwd: cwd)
            }
        }

        switch event {
        case "SessionStart":
            log("session opened (\(json["source"] as? String ?? "startup"))")
            MarkerStore.upsert(presence, agent: agent, session: session, kind: "session", pid: pid, cwd: cwd)

        case "SessionEnd":
            log("session closed (\(json["reason"] as? String ?? "exit"))")
            MarkerStore.removeSession(agent: agent, session: session)

        case "Stop":
            log("turn finished" + duration(of: turn))
            MarkerStore.remove(turn)

        case "SubagentStart":
            touchPresence()
            if let agentId {
                log("subagent started (\(agentType ?? "agent") \(agentId.prefix(8)))")
                MarkerStore.upsert(sub(agentId), agent: agent, session: session, kind: "subagent", pid: pid, cwd: cwd, label: agentType)
            }

        case "SubagentStop":
            if let agentId {
                log("subagent finished (\(agentType ?? "agent") \(agentId.prefix(8)))" + duration(of: sub(agentId)))
                MarkerStore.remove(sub(agentId))
            }

        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PreCompact":
            // Any sign of life: refresh (or recreate) the marker of whoever is acting.
            touchPresence()
            if event == "UserPromptSubmit" { log("prompt submitted — turn started") }
            if let agentId {
                MarkerStore.upsert(sub(agentId), agent: agent, session: session, kind: "subagent", pid: pid, cwd: cwd, label: agentType)
            } else {
                if event != "UserPromptSubmit" && !FileManager.default.fileExists(atPath: turn.path) {
                    log("working again (\(event)) — turn resumed")
                }
                MarkerStore.upsert(turn, agent: agent, session: session, kind: "turn", pid: pid, cwd: cwd)
            }

        default:
            break
        }
        exit(0)
    }

    private static func readStdin() -> Data {
        if isatty(STDIN_FILENO) != 0 { return Data() }
        return FileHandle.standardInput.readDataToEndOfFile()
    }

    /// Walk up from our parent, skipping shells, to find the agent process itself.
    private static func agentPid() -> Int32 {
        let table = ProcessTree.snapshot()
        var pid = getppid()
        for _ in 0..<6 {
            guard let info = table[pid] else { break }
            if !ProcessTree.shells.contains(info.name) && info.name != "VibeWake" { return pid }
            if info.ppid <= 1 { break }
            pid = info.ppid
        }
        return getppid()
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
