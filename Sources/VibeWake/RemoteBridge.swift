import Foundation

/// What the phone sees of this Mac (see protocol/PROTOCOL.md). Never includes inbox sockets or tokens.
struct RemoteSnapshot: Codable, Equatable {
    struct Battery: Codable, Equatable { var onBattery: Bool; var percent: Int }
    struct Reply: Codable, Equatable { var text: String; var at: Double; var truncated: Bool }
    struct Item: Codable, Equatable { var id: String; var text: String; var mode: String; var createdAt: Double }
    struct Session: Codable, Equatable {
        var id: String
        var agent: String
        var session: String
        var project: String?
        var cwd: String?
        var title: String
        var state: String
        var stateSince: Double?
        var limitedUntil: Double?
        var subagents: Int
        var canReceive: Bool
        var headless: Bool
        var blocked: String?
        var next: String?
        var queue: [Item]
        var reply: Reply?
    }
    var paused: Bool
    var remoteControl: Bool
    var lidClosed: Bool
    var battery: Battery?
    var nobodyAtScreen: Bool
    var wakeIntervalMinutes: Double
    var projects: [String]
    var sessions: [Session]
}

/// Connects the relay client to the autopilot: snapshots out, commands in, events on state changes.
final class RemoteBridge {
    let client = RemoteClient()
    let headless = HeadlessRunner()
    private let autopilot: Autopilot
    /// Read / change the menu bar app's pause switch.
    var isPaused: () -> Bool = { false }
    var setPaused: (Bool) -> Void = { _ in }

    private var lastStates: [String: String]?
    private var lastSteady: RemoteSnapshot?
    private var lastSent: Double = 0
    private static let replyPreview = 8 * 1024

    init(autopilot: Autopilot) {
        self.autopilot = autopilot
        client.onCommand = { [weak self] id, cmd in self?.run(id, cmd) ?? (false, "not ready", nil) }
        client.onConnected = { [weak self] in self?.update(force: true) }
        headless.onFinish = { [weak self] _, _ in self?.autopilot.tick(); self?.update() }
        autopilot.isHeadless = { [weak self] id in self?.headless.chat(id) != nil }
    }

    /// Call after every autopilot tick.
    func update(force: Bool = false) {
        client.reloadConfig()
        let settings = autopilot.settings
        ProjectStore.remember(autopilot.sessions.compactMap(\.cwd))
        headless.runQueues(live: Set(autopilot.sessions.map(\.id)), settings: settings)
        let snap = snapshot()
        detectEvents(snap)
        guard client.status == .connected else { return }
        // `next` holds countdowns ("nudge in 4m 12s") that change every tick: alone, they're sent every 30 s.
        var steady = snap
        for i in steady.sessions.indices { steady.sessions[i].next = nil }
        let t = Date().timeIntervalSince1970
        guard force || steady != lastSteady || t - lastSent >= 30 else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        if let data = try? enc.encode(snap) {
            if force { client.sendSnapshot(Data()) } // reset "unchanged" check
            client.sendSnapshot(data)
            lastSteady = steady
            lastSent = t
        }
    }

    // MARK: - Snapshot

    func snapshot() -> RemoteSnapshot {
        let settings = autopilot.settings
        var sessions = autopilot.sessions.map { s -> RemoteSnapshot.Session in
            let headlessChat = headless.chat(s.id)
            return RemoteSnapshot.Session(
                id: s.id, agent: s.agent, session: s.session, project: s.project, cwd: s.cwd, title: s.displayTitle,
                state: Self.name(s.state), stateSince: Self.since(s), limitedUntil: { if case .limited(let u) = s.state { return u }; return nil }(),
                subagents: s.subagents, canReceive: s.agent == "claude" && s.canReceive, headless: headlessChat != nil,
                blocked: autopilot.blocked[s.id]?.reason, next: s.next, queue: Self.items(s.queue),
                reply: Self.reply(transcript: s.presence?.transcript ?? headlessChat?.transcript, fallback: nil))
        }
        let live = Set(sessions.map(\.id))
        for chat in headless.chats.reversed() where !live.contains(chat.key) {
            let project = (chat.cwd as NSString).lastPathComponent
            let title = SessionInbox.title(transcript: chat.transcript) ?? "\(project) · \(chat.session.prefix(8))"
            let running = headless.isRunning(chat.session)
            let next: String?
            if running { next = nil }
            else if let at = headless.continueAt(chat) {
                next = settings.autoContinue ? "“\(settings.continuePrompt)” at \(Autopilot.clock(at))" : "usage limit (auto-continue off)"
            } else { next = PromptQueue.load(chat.key).isEmpty ? nil : "runs queued prompt" }
            sessions.append(RemoteSnapshot.Session(
                id: chat.key, agent: "claude", session: chat.session, project: project, cwd: chat.cwd, title: title,
                state: running ? "working" : chat.limitResetAt != nil ? "limited" : chat.failed == nil ? "finished" : "failed",
                stateSince: running ? chat.startedAt : chat.endedAt, limitedUntil: running ? nil : chat.limitResetAt, subagents: 0,
                canReceive: !running, headless: true, blocked: chat.failed, next: next,
                queue: Self.items(PromptQueue.load(chat.key)),
                reply: Self.reply(transcript: chat.transcript, fallback: chat.lastResult)))
        }
        let battery = SleepController.battery.map { RemoteSnapshot.Battery(onBattery: $0.onBattery, percent: $0.percent) }
        return RemoteSnapshot(paused: isPaused(), remoteControl: settings.remoteControl, lidClosed: SleepController.isLidClosed,
                              battery: battery, nobodyAtScreen: HeadlessRunner.nobodyAtScreen,
                              wakeIntervalMinutes: settings.wakeIntervalMinutes, projects: ProjectStore.list(settings), sessions: sessions)
    }

    private static func name(_ state: AgentSession.State) -> String {
        switch state {
        case .working: return "working"
        case .idle: return "idle"
        case .limited: return "limited"
        case .stalled: return "stalled"
        case .waiting: return "waiting"
        }
    }

    private static func since(_ s: AgentSession) -> Double? {
        switch s.state {
        case .working: return s.turn?.startedAt ?? s.startedAt
        case .idle: return s.presence?.lastStopAt
        case .limited: return s.presence?.lastStopAt
        case .stalled(let t), .waiting(let t): return t
        }
    }

    private static func items(_ queue: [QueuedPrompt]) -> [RemoteSnapshot.Item] {
        queue.map { .init(id: $0.id.uuidString, text: $0.text, mode: $0.mode.rawValue, createdAt: $0.createdAt) }
    }

    private static func reply(transcript: String?, fallback: String?) -> RemoteSnapshot.Reply? {
        let r = SessionInbox.lastReply(transcript: transcript) ?? fallback.map { ($0, 0) }
        guard let r else { return nil }
        let cut = r.text.count > replyPreview
        return .init(text: cut ? String(r.text.prefix(replyPreview)) : r.text, at: r.at, truncated: cut)
    }

    // MARK: - Events (push notifications)

    private func detectEvents(_ snap: RemoteSnapshot) {
        let now = Dictionary(snap.sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        defer { lastStates = now }
        guard let before = lastStates else { return } // nothing to compare on the first tick
        let busy: Set<String> = ["working", "stalled", "waiting"]
        for s in snap.sessions {
            guard let old = before[s.id], old != s.state else { continue }
            let kind: String
            switch s.state {
            case "finished":
                kind = "finished"
            case "idle":
                // A headless chat is done when its process exits ("finished"), and looks idle while a run starts.
                guard busy.contains(old), !s.headless else { continue }
                kind = "finished"
            case "failed": kind = "failed"
            case "limited": kind = "limited"
            case "waiting": kind = "waiting"
            default: continue
            }
            let text: String
            switch kind {
            case "limited": text = s.limitedUntil.map { "Usage limit until \(Autopilot.clock($0))" } ?? "Usage limit reached"
            case "waiting": text = "Waiting for your input in the chat"
            case "failed": text = s.blocked ?? "failed"
            default: text = s.reply?.text ?? "Finished"
            }
            client.sendEvent(kind: kind, sessionId: s.id, title: s.title, text: text)
        }
    }

    // MARK: - Commands

    private typealias Result = (ok: Bool, error: String?, result: Any?)

    private func run(_ id: String, _ cmd: [String: Any]) -> Result {
        let type = cmd["type"] as? String ?? ""
        let r = execute(type, cmd)
        Log.write("remote", "phone: \(type)\(r.ok ? "" : " failed: \(r.error ?? "?")")")
        autopilot.tick()
        update()
        return r
    }

    private func execute(_ type: String, _ cmd: [String: Any]) -> Result {
        let settings = autopilot.settings
        let sid = cmd["sessionId"] as? String ?? ""
        let snap = snapshot()
        let session = snap.sessions.first { $0.id == sid }
        let readOnly: Set<String> = ["fetchReply"]
        if !settings.remoteControl && !readOnly.contains(type) { return (false, "remote control is turned off on this Mac", nil) }

        func itemId() -> UUID? { (cmd["itemId"] as? String).flatMap(UUID.init(uuidString:)) }

        switch type {
        case "queueAdd":
            guard session != nil else { return (false, "chat not found", nil) }
            guard let text = cmd["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (false, "empty prompt", nil) }
            let mode = QueuedPrompt.Mode(rawValue: cmd["mode"] as? String ?? "") ?? .sameChat
            PromptQueue.add(sid, QueuedPrompt(text: text, mode: mode))
            return (true, nil, nil)

        case "queueRemove":
            guard let item = itemId() else { return (false, "bad item id", nil) }
            PromptQueue.remove(sid, id: item)
            return (true, nil, nil)

        case "queueMove":
            guard let item = itemId(), let by = cmd["by"] as? Int else { return (false, "bad item id or offset", nil) }
            PromptQueue.move(sid, id: item, by: by)
            return (true, nil, nil)

        case "queueEdit":
            guard let item = itemId() else { return (false, "bad item id", nil) }
            var found = false
            PromptQueue.update(sid) { list in
                guard let i = list.firstIndex(where: { $0.id == item }) else { return }
                found = true
                if let t = cmd["text"] as? String, !t.isEmpty { list[i].text = t }
                if let m = (cmd["mode"] as? String).flatMap(QueuedPrompt.Mode.init(rawValue:)) { list[i].mode = m }
            }
            return found ? (true, nil, nil) : (false, "queue item not found (already sent?)", nil)

        case "sendNow", "askStatus", "continue":
            let text = type == "askStatus" ? settings.statusPrompt : type == "continue" ? settings.continuePrompt : cmd["text"] as? String ?? ""
            guard !text.isEmpty else { return (false, "empty prompt", nil) }
            guard let s = session else { return (false, "chat not found", nil) }
            if let chat = headless.chat(sid), !autopilot.sessions.contains(where: { $0.id == sid }) {
                // Finished headless chat: continue it with --resume.
                return headless.run(prompt: text, cwd: chat.cwd, resume: chat.session, settings: settings).map { (false, $0, nil) } ?? (true, nil, nil)
            }
            if headless.chat(sid) != nil, s.state != "working" && s.state != "stalled" && s.state != "waiting" {
                // Turn over, process about to exit: run it with --resume right after instead.
                PromptQueue.update(sid) { $0.insert(QueuedPrompt(text: text, mode: .sameChat), at: 0) }
                return (true, nil, ["queued": true])
            }
            guard s.canReceive else { return (false, "this chat can't receive prompts", nil) }
            autopilot.sendNow(text, to: sid)
            if let b = autopilot.blocked[sid] { return (false, b.reason, nil) }
            return (true, nil, nil)

        case "resumeQueue":
            headless.clearFailure(sid)
            autopilot.resumeQueue(sid)
            return (true, nil, nil)

        case "newSession":
            guard let cwd = cmd["cwd"] as? String, let prompt = cmd["prompt"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (false, "missing folder or prompt", nil) }
            // Only folders this Mac already works in: the phone can't make Claude run anywhere it likes.
            guard ProjectStore.list(settings).contains(cwd) else { return (false, "\(cwd) is not a known project on this Mac", nil) }
            let editor = settings.remoteNewChats == "editor" || (settings.remoteNewChats == "auto" && !HeadlessRunner.nobodyAtScreen)
            if editor {
                let started = autopilot.openRemoteChat(cwd: cwd, text: prompt) { [weak self] cwd, text in
                    guard let self else { return }
                    if let e = self.headless.run(prompt: text, cwd: cwd, settings: self.autopilot.settings) {
                        self.client.sendEvent(kind: "failed", sessionId: "", title: (cwd as NSString).lastPathComponent, text: e)
                    }
                }
                if started { return (true, nil, ["via": "editor"]) }
                if settings.remoteNewChats == "editor" { return (false, "could not open a new editor chat", nil) }
            }
            return headless.run(prompt: prompt, cwd: cwd, settings: settings).map { (false, $0, nil) } ?? (true, nil, ["via": "headless"])

        case "fetchReply":
            let transcript = autopilot.sessions.first { $0.id == sid }?.presence?.transcript ?? headless.chat(sid)?.transcript
            guard let r = SessionInbox.lastReply(transcript: transcript) ?? headless.chat(sid)?.lastResult.map({ ($0, 0) }) else {
                return (false, "no reply yet", nil)
            }
            return (true, nil, ["text": r.text, "at": r.at])

        case "setPaused":
            guard let p = cmd["paused"] as? Bool else { return (false, "missing paused", nil) }
            setPaused(p)
            return (true, nil, nil)

        default:
            return (false, "unknown command \(type)", nil)
        }
    }
}
