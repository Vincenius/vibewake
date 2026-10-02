import AppKit
import Combine

/// User-tunable autopilot settings, persisted in ~/.vibewake/state/settings.json.
struct AutopilotSettings: Codable, Equatable {
    var autoContinue = true
    var stallNudge = true
    var queueEnabled = true
    var stallMinutes: Double = 20
    var maxNudges = 3
    var continuePrompt = "continue"
    var statusPrompt = "what is the status?"
    /// URL scheme of the editor running the Claude Code extension (vscode, cursor, …).
    var editorScheme = "vscode"

    static var url: URL { Paths.state.appendingPathComponent("settings.json") }

    static func load() -> AutopilotSettings {
        guard let data = try? Data(contentsOf: url) else { return AutopilotSettings() }
        // Decode field by field so new settings get defaults.
        var s = AutopilotSettings()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return s }
        if let v = obj["autoContinue"] as? Bool { s.autoContinue = v }
        if let v = obj["stallNudge"] as? Bool { s.stallNudge = v }
        if let v = obj["queueEnabled"] as? Bool { s.queueEnabled = v }
        if let v = obj["stallMinutes"] as? Double, v >= 1 { s.stallMinutes = v }
        if let v = obj["maxNudges"] as? Int { s.maxNudges = v }
        if let v = obj["continuePrompt"] as? String, !v.isEmpty { s.continuePrompt = v }
        if let v = obj["statusPrompt"] as? String, !v.isEmpty { s.statusPrompt = v }
        if let v = obj["editorScheme"] as? String, !v.isEmpty { s.editorScheme = v }
        return s
    }

    func save() {
        Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}

/// One agent chat, idle or working, as shown in the Agents window.
struct AgentSession: Identifiable {
    enum State: Equatable {
        case working, idle
        case limited(until: Double)
        case stalled(since: Double)
        /// Mid-turn, blocked on a permission prompt or question in the chat.
        case waiting(since: Double)
    }

    let id: String          // "<agent>-<session>", also the queue key
    let agent: String
    let session: String
    let pid: Int32
    let cwd: String?
    let title: String?
    let presence: Marker?
    let turn: Marker?
    let subagents: Int
    /// Most recent heartbeat of the main turn or any subagent.
    let lastHeartbeat: Double?
    let state: State
    let queue: [QueuedPrompt]
    /// What the autopilot will do next, for display.
    var next: String?

    var project: String? { cwd.map { ($0 as NSString).lastPathComponent } }
    var displayTitle: String { title ?? "\(project ?? agent) · \(session.prefix(8))" }
    var canReceive: Bool { presence?.socket != nil }
    var startedAt: Double { presence?.startedAt ?? turn?.startedAt ?? 0 }

    var stateText: String {
        switch state {
        case .working: return "working " + AppDelegate.elapsed(since: turn?.startedAt ?? startedAt)
        case .idle: return presence?.lastStopAt.map { "idle " + AppDelegate.elapsed(since: $0) } ?? "idle"
        case .limited(let until):
            return until > Date().timeIntervalSince1970 ? "usage limit until \(Autopilot.clock(until))"
                                                        : "usage limit lifted at \(Autopilot.clock(until))"
        case .stalled(let since): return "silent for " + AppDelegate.elapsed(since: since)
        case .waiting(let since): return "waiting for your input " + AppDelegate.elapsed(since: since)
        }
    }
}

/// Watches agent chats and acts on them through their inbox socket:
/// continues after a usage limit, nudges stalled turns, and runs queued prompts.
final class Autopilot: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var settings = AutopilotSettings.load() {
        didSet { if settings != oldValue { settings.save() } }
    }

    /// Something we sent and the turn it should start.
    private struct Delivery { var at: Double; var what: String; var started = false
        /// The queue item this was, put back in front of the queue if no turn starts.
        var item: QueuedPrompt? }
    private var deliveries: [String: Delivery] = [:]
    /// Stall nudges per session: the heartbeat they were sent at and how many in a row.
    private var nudges: [String: (heartbeat: Double, at: Double, count: Int)] = [:]
    /// Chats we stopped acting on after a failed delivery: until the user resumes, or 10 minutes pass.
    @Published private(set) var blocked: [String: (reason: String, at: Double)] = [:]
    /// A "new chat" prompt waiting for the new VS Code tab to register.
    /// The queue item stays in its queue until it has been handed over, so a failure doesn't lose it.
    private struct PendingNewChat { let item: QueuedPrompt; let cwd: String; let openedAt: Double; let from: String }
    private var pendingNewChat: PendingNewChat?
    /// Why the Mac should stay awake for the autopilot (a continue, nudge or queued prompt is pending).
    private(set) var keepAwakeReasons: [String] = []

    private var lastPrune: Double = 0

    init() {
        if !FileManager.default.fileExists(atPath: AutopilotSettings.url.path) { settings.save() }
    }

    private static let idleSettle: Double = 5
    private static let deliveryTimeout: Double = 120
    private static let newChatTimeout: Double = 60
    private static let blockedRetry: Double = 10 * 60

    // MARK: - Registry

    static func collectSessions(stallMinutes: Double = AutopilotSettings.load().stallMinutes) -> [AgentSession] {
        struct Group { var presence: Marker?; var turn: Marker?; var subs: [Marker] = [] }
        var groups: [String: Group] = [:]
        let table = ProcessTree.snapshot()
        let minShellAge = ActivityMonitor.Config().minShellAge
        for (_, m) in MarkerStore.all() where ProcessTree.isAlive(m, in: table) {
            let key = "\(m.agent)-\(m.session)"
            var g = groups[key] ?? Group()
            switch m.kind {
            case "turn": g.turn = m
            case "subagent": g.subs.append(m)
            default: g.presence = m
            }
            groups[key] = g
        }

        let now = Date().timeIntervalSince1970
        let staleAfter = ActivityMonitor.Config().staleAfter
        return groups.compactMap { key, g -> AgentSession? in
            guard let any = g.presence ?? g.turn ?? g.subs.first else { return nil }
            // A turn interrupted with Esc never fires Stop; the transcript says so.
            let turn = g.turn.flatMap { t in
                SessionInbox.lastTurnInterrupted(transcript: g.presence?.transcript, after: t.startedAt) ? nil : t
            }
            let subs = g.subs.filter { now - $0.touchedAt < staleAfter }
            let heartbeat = ([turn].compactMap { $0 } + subs).map(\.touchedAt).max()
            // A long-running shell (build, tests) is working, not stalled, even without hook heartbeats.
            let shellRunning = !ProcessTree.longRunningShellChildren(of: any.pid, in: table, minAge: minShellAge).isEmpty

            let state: AgentSession.State
            if turn == nil && subs.isEmpty {
                if let reset = g.presence?.limitResetAt { state = .limited(until: reset) } else { state = .idle }
            } else if turn != nil, let waiting = g.presence?.awaitingInputAt {
                state = .waiting(since: waiting)
            } else if let heartbeat, turn != nil, !shellRunning, now - heartbeat >= stallMinutes * 60 {
                state = .stalled(since: heartbeat)
            } else {
                state = .working
            }
            return AgentSession(id: key, agent: any.agent, session: any.session, pid: any.pid,
                                cwd: g.presence?.cwd ?? any.cwd,
                                title: SessionInbox.title(transcript: g.presence?.transcript) ?? g.presence?.title,
                                presence: g.presence, turn: turn, subagents: subs.count,
                                lastHeartbeat: heartbeat, state: state, queue: PromptQueue.load(key))
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Loop (called from the app timer)

    func tick() {
        let now = Date().timeIntervalSince1970
        let onDisk = AutopilotSettings.load() // pick up hand edits of settings.json
        if onDisk != settings { settings = onDisk }
        var list = Self.collectSessions(stallMinutes: settings.stallMinutes)
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Forget state of closed sessions.
        deliveries = deliveries.filter { byId[$0.key] != nil }
        nudges = nudges.filter { byId[$0.key] != nil }
        blocked = blocked.filter { byId[$0.key] != nil && now - $0.value.at < Self.blockedRetry }

        for i in list.indices {
            let s = list[i]
            trackDelivery(s, now: now)
            list[i].next = act(on: s, now: now)
        }
        resolveNewChat(list, now: now)
        pruneQueues(of: byId, now: now)
        keepAwakeReasons = list.compactMap { keepAwakeReason($0, now: now) } + (pendingNewChat.map { _ in ["opening a new chat"] } ?? [])
        sessions = list
    }

    /// Something the autopilot will do for this chat that needs the Mac awake, if any.
    private func keepAwakeReason(_ s: AgentSession, now: Double) -> String? {
        guard s.agent == "claude", s.canReceive, blocked[s.id] == nil else { return nil }
        if let d = deliveries[s.id], !d.started { return "\(label(s)): waiting for “\(d.what)” to start" }
        switch s.state {
        case .limited:
            return settings.autoContinue ? "\(label(s)): continue after usage limit" : nil
        case .stalled(let since):
            guard settings.stallNudge else { return nil }
            let n = nudges[s.id]
            let count = n?.heartbeat == since ? n?.count ?? 0 : 0
            return count < settings.maxNudges ? "\(label(s)): nudging stalled chat" : nil
        case .idle:
            guard settings.queueEnabled, let item = s.queue.first else { return nil }
            return item.mode == .newChat && s.cwd == nil ? nil : "\(label(s)): queued prompt"
        case .working, .waiting:
            return nil
        }
    }

    /// Queues of chats that are gone (closed, /clear, crashed) would never run; drop them, but say so.
    private func pruneQueues(of live: [String: AgentSession], now: Double) {
        guard now - lastPrune > 60 else { return }
        lastPrune = now
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.queue.path)) ?? []
        let liveFiles = Set(live.keys.map { PromptQueue.url(for: $0).lastPathComponent })
        for f in files where f.hasSuffix(".json") && !liveFiles.contains(f) {
            let url = Paths.queue.appendingPathComponent(f)
            let items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([QueuedPrompt].self, from: $0) } ?? []
            for item in items {
                Log.write("autopilot", "chat \(f.dropLast(5)) is closed — dropped queued prompt “\(Self.short(item.text))”")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Notice whether what we sent actually started a turn.
    private func trackDelivery(_ s: AgentSession, now: Double) {
        guard var d = deliveries[s.id] else { return }
        if !d.started, let t = s.turn, t.startedAt >= d.at - 1 { d.started = true }
        if !d.started, let stop = s.presence?.lastStopAt, stop > d.at { d.started = true }
        deliveries[s.id] = d
        if !d.started && now - d.at > Self.deliveryTimeout {
            deliveries[s.id] = nil
            blocked[s.id] = ("“\(d.what)” did not start a turn — waiting for approval in the chat?", now)
            Log.write("autopilot", "\(label(s)): “\(d.what)” sent \(Int(Self.deliveryTimeout))s ago but no turn started — queue paused for this chat")
            if let item = d.item {
                // Don't lose it: put it back where it was, so it runs (or can be removed) once resumed.
                PromptQueue.update(s.id) { $0 = [item] + $0.filter { $0.id != item.id } }
            }
        }
    }

    /// Decide and perform the next action for one session; returns a description of what's pending.
    private func act(on s: AgentSession, now: Double) -> String? {
        guard s.agent == "claude", s.canReceive else { return s.queue.isEmpty ? nil : "can't deliver (no inbox socket)" }
        if let d = deliveries[s.id], !d.started { return "sent “\(d.what)”…" }
        if let b = blocked[s.id] { return "paused: \(b.reason)" }

        switch s.state {
        case .limited(let until):
            guard settings.autoContinue else { return "usage limit (auto-continue off)" }
            let at = until + 60
            if now >= at {
                if deliver(settings.continuePrompt, to: s, now: now) {
                    MarkerStore.modify(presenceURL(s)) { $0.limitResetAt = nil }
                }
                return nil
            }
            return "“\(settings.continuePrompt)” at \(Self.clock(at))"

        case .stalled(let since):
            guard settings.stallNudge else { return nil }
            var n = nudges[s.id] ?? (heartbeat: 0, at: 0, count: 0)
            if n.heartbeat != since { n = (since, 0, 0) } // new silence window
            let wait = settings.stallMinutes * 60
            if n.count >= settings.maxNudges { return "stalled (gave up after \(n.count) nudges)" }
            if n.count == 0 || now - n.at >= wait {
                if deliver(settings.statusPrompt, to: s, now: now, expectTurn: false) {
                    n = (since, now, n.count + 1)
                }
                nudges[s.id] = n
                return nil
            }
            nudges[s.id] = n
            return "nudge again in \(formatDuration(n.at + wait - now))"

        case .working:
            if let hb = s.lastHeartbeat, settings.stallNudge {
                return s.turn == nil ? nil : "nudge in \(formatDuration(hb + settings.stallMinutes * 60 - now))"
            }
            return nil

        case .waiting:
            return "waiting for you in the chat (no nudges)"

        case .idle:
            break
        }

        // Idle: run the queue.
        guard let item = s.queue.first else { return nil }
        guard settings.queueEnabled else { return "queue paused" }
        if let stop = s.presence?.lastStopAt, now - stop < Self.idleSettle { return "next prompt in a moment" }

        switch item.mode {
        case .sameChat:
            if deliver(item.text, to: s, now: now, item: item) { PromptQueue.remove(s.id, id: item.id) }
        case .newChat:
            if let p = pendingNewChat { return p.item.id == item.id ? "opening a new chat…" : "waiting for another new chat to open" }
            guard let cwd = s.cwd else { return "no project folder for a new chat" }
            openNewChat(item, cwd: cwd, from: s, now: now)
        }
        return nil
    }

    // MARK: - Actions

    @discardableResult
    private func deliver(_ text: String, to s: AgentSession, now: Double, expectTurn: Bool = true, item: QueuedPrompt? = nil) -> Bool {
        guard let presence = s.presence else { return false }
        do {
            try SessionInbox.send(text, to: presence)
            Log.write("autopilot", "\(label(s)) ← “\(Self.short(text))”")
            if expectTurn { deliveries[s.id] = Delivery(at: now, what: Self.short(text), item: item) }
            return true
        } catch {
            blocked[s.id] = (error.localizedDescription, now)
            Log.write("autopilot", "\(label(s)): could not send “\(Self.short(text))”: \(error.localizedDescription)")
            return false
        }
    }

    private func openNewChat(_ item: QueuedPrompt, cwd: String, from s: AgentSession, now: Double) {
        Log.write("autopilot", "\(label(s)): opening a new chat in \((cwd as NSString).lastPathComponent) for “\(Self.short(item.text))”")
        guard openEditor(cwd: cwd, prefill: nil) else { return failNewChat(from: s.id, now: now) }
        pendingNewChat = PendingNewChat(item: item, cwd: cwd, openedAt: now, from: s.id)
    }

    private func failNewChat(from id: String, now: Double) {
        let reason = "could not open a new chat with the “\(settings.editorScheme)” URL scheme (see editorScheme in settings.json)"
        blocked[id] = (reason, now)
        Log.write("autopilot", "\(reason) — prompt kept in the queue")
    }

    /// Hand the pending prompt to the chat that just opened, or fall back to a pre-filled tab.
    private func resolveNewChat(_ list: [AgentSession], now: Double) {
        guard let p = pendingNewChat else { return }
        if let fresh = list.first(where: { $0.id != p.from && $0.cwd == p.cwd && $0.canReceive
                                            && ($0.presence?.startedAt ?? 0) >= p.openedAt - 2 }) {
            pendingNewChat = nil
            if deliver(p.item.text, to: fresh, now: now) {
                PromptQueue.remove(p.from, id: p.item.id)
            } else {
                blocked[p.from] = ("the new chat could not receive the prompt", now) // don't open tab after tab
            }
        } else if now - p.openedAt > Self.newChatTimeout {
            pendingNewChat = nil
            if openEditor(cwd: p.cwd, prefill: p.item.text) {
                PromptQueue.remove(p.from, id: p.item.id)
                Log.write("autopilot", "new chat did not register within \(Int(Self.newChatTimeout))s — opened it with the prompt pre-filled instead")
            } else {
                failNewChat(from: p.from, now: now)
            }
        }
    }

    @discardableResult
    private func openEditor(cwd: String, prefill: String?) -> Bool {
        var c = URLComponents()
        c.scheme = settings.editorScheme
        c.host = "anthropic.claude-code"
        c.path = "/open"
        c.queryItems = [URLQueryItem(name: "cwd", value: cwd)] + (prefill.map { [URLQueryItem(name: "q", value: String($0.prefix(5000)))] } ?? [])
        guard let url = c.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Manual actions (Agents window, CLI)

    func sendNow(_ text: String, to id: String) {
        guard let s = Self.collectSessions(stallMinutes: settings.stallMinutes).first(where: { $0.id == id }) else { return }
        blocked[id] = nil
        // Mid-turn, Claude reads the message between tool calls and no new turn starts.
        let expectTurn: Bool
        switch s.state {
        case .idle, .limited: expectTurn = true
        case .working, .stalled, .waiting: expectTurn = false
        }
        deliver(text, to: s, now: Date().timeIntervalSince1970, expectTurn: expectTurn)
        tick()
    }

    func resumeQueue(_ id: String) {
        blocked[id] = nil
        deliveries[id] = nil
        nudges[id] = nil
        tick()
    }

    // MARK: - Helpers

    private func presenceURL(_ s: AgentSession) -> URL {
        MarkerStore.url(agent: s.agent, session: s.session, kind: "session")
    }

    private func label(_ s: AgentSession) -> String {
        "\(s.project ?? s.agent) · \(s.title.map { "“\($0)”" } ?? String(s.session.prefix(8)))"
    }

    static func short(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > 60 ? one.prefix(57) + "…" : one
    }

    static func clock(_ t: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        let style: DateFormatter.Style = Calendar.current.isDateInToday(date) ? .none : .short
        return DateFormatter.localizedString(from: date, dateStyle: style, timeStyle: .short)
    }
}
