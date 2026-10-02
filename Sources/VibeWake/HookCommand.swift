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
        let env = ProcessInfo.processInfo.environment
        let socket = env["CLAUDE_CODE_MESSAGING_SOCKET"]
        let token = env["CLAUDE_CODE_MESSAGING_TOKEN"]
        let transcript = json["transcript_path"] as? String

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

        /// Session marker: (re)create it, and keep the inbox address and transcript current.
        /// `clearAwaiting`: the main agent is acting again, so it no longer waits for the user.
        func touchPresence(clearAwaiting: Bool = false, _ extra: ((inout Marker) -> Void)? = nil) {
            let m = MarkerStore.read(presence)
            let stale = m == nil || (socket != nil && m?.socket != socket) || (transcript != nil && m?.transcript != transcript)
                || (clearAwaiting && m?.awaitingInputAt != nil)
            guard stale || extra != nil else { return }
            MarkerStore.upsert(presence, agent: agent, session: session, kind: "session", pid: pid, cwd: cwd) { m in
                if let socket { m.socket = socket; m.token = token }
                if let transcript { m.transcript = transcript }
                if clearAwaiting { m.awaitingInputAt = nil }
                extra?(&m)
            }
        }

        switch event {
        case "SessionStart":
            log("session opened (\(json["source"] as? String ?? "startup"))")
            touchPresence { m in
                if let title = json["session_title"] as? String, !title.isEmpty { m.title = title }
            }

        case "SessionEnd":
            log("session closed (\(json["reason"] as? String ?? "exit"))")
            MarkerStore.removeSession(agent: agent, session: session)

        case "Stop":
            log("turn finished" + duration(of: turn))
            MarkerStore.remove(turn)
            touchPresence(clearAwaiting: true) { m in
                m.lastStopAt = Date().timeIntervalSince1970
                m.limitResetAt = nil
            }

        case "StopFailure":
            let error = json["error_type"] as? String ?? "unknown"
            let reset = (json["reset_time"] as? NSNumber)?.doubleValue
            let at = reset.map { " — resets " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: $0), dateStyle: .none, timeStyle: .short) } ?? ""
            log("turn failed (\(error))\(at)" + duration(of: turn))
            MarkerStore.remove(turn)
            touchPresence(clearAwaiting: true) { m in
                m.lastStopAt = Date().timeIntervalSince1970
                if error == "rate_limit" { m.limitResetAt = reset ?? Date().timeIntervalSince1970 + 30 * 60 }
            }

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
            if event == "UserPromptSubmit" {
                log("prompt submitted — turn started")
                touchPresence(clearAwaiting: true) { $0.limitResetAt = nil } // continued by hand (or by us)
            } else {
                // A subagent acting doesn't mean the main agent's permission prompt was answered.
                touchPresence(clearAwaiting: agentId == nil)
            }
            if let agentId {
                MarkerStore.upsert(sub(agentId), agent: agent, session: session, kind: "subagent", pid: pid, cwd: cwd, label: agentType)
            } else {
                if event == "UserPromptSubmit" {
                    // A new turn: drop a marker left by a turn interrupted with Esc (no Stop), so startedAt is fresh.
                    MarkerStore.remove(turn)
                } else if !FileManager.default.fileExists(atPath: turn.path) {
                    log("working again (\(event)) — turn resumed")
                }
                MarkerStore.upsert(turn, agent: agent, session: session, kind: "turn", pid: pid, cwd: cwd)
            }

        case "Notification":
            // Permission prompts and questions block the turn until the user answers: not a stall.
            let type = json["notification_type"] as? String
            let message = json["message"] as? String ?? ""
            if type == "permission_prompt" || type == "elicitation_dialog"
                || (type == nil && message.localizedCaseInsensitiveContains("permission")) {
                log("waiting for your input (\(message.isEmpty ? type ?? "notification" : message))")
                touchPresence { $0.awaitingInputAt = Date().timeIntervalSince1970 }
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
