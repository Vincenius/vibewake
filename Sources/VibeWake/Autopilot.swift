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
    // Remote control (phone app via the relay server, see RemoteClient).
    /// Off switch for everything the phone can do; the Mac still reports its state.
    var remoteControl = true
    /// While asleep, wake every this many minutes to pick up prompts from the phone (0 = never).
    var wakeIntervalMinutes: Double = 15
    /// The same at night, from nightStartHour to nightEndHour (local time, whole hours).
    var nightWakeIntervalMinutes: Double = 60
    var nightStartHour = 23
    var nightEndHour = 6
    /// Where chats the phone starts run: "auto" (editor tab if someone could see it, else headless), "headless", "editor".
    var remoteNewChats = "auto"
    /// --permission-mode for chats the phone starts while nobody is at the Mac.
    var headlessPermissionMode = "acceptEdits"
    /// Path to the `claude` binary for those chats; empty = find it.
    var claudePath = ""
    /// Extra project folders the phone may start chats in (besides folders of recent chats).
    var remoteProjects: [String] = []
    /// When a chat ends (closed, /clear, crashed), stop what it left running: dev servers, watchers, background tasks.
    var closeLeftovers = true

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
        if let v = obj["remoteControl"] as? Bool { s.remoteControl = v }
        if let v = obj["wakeIntervalMinutes"] as? Double, v >= 0 { s.wakeIntervalMinutes = v == 0 ? 0 : max(5, v) }
        if let v = obj["nightWakeIntervalMinutes"] as? Double, v >= 0 { s.nightWakeIntervalMinutes = v == 0 ? 0 : max(5, v) }
        if let v = obj["nightStartHour"] as? Int, (0...23).contains(v) { s.nightStartHour = v }
        if let v = obj["nightEndHour"] as? Int, (0...23).contains(v) { s.nightEndHour = v }
        if let v = obj["remoteNewChats"] as? String, ["auto", "headless", "editor"].contains(v) { s.remoteNewChats = v }
        if let v = obj["headlessPermissionMode"] as? String, !v.isEmpty { s.headlessPermissionMode = v }
        if let v = obj["claudePath"] as? String { s.claudePath = v }
        if let v = obj["remoteProjects"] as? [String] { s.remoteProjects = v }
        if let v = obj["closeLeftovers"] as? Bool { s.closeLeftovers = v }
        return s
    }

    func save() {
        Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    // MARK: Check-in schedule (phone app)

    /// Choices offered for the check-in intervals, in minutes (0 = never).
    static let wakeIntervalChoices: [Double] = [0, 5, 10, 15, 20, 30, 60, 120]

    static func describeInterval(_ minutes: Double) -> String {
        switch minutes {
        case 0: return "never"
        case 60: return "every hour"
        case let m where m > 60 && m.truncatingRemainder(dividingBy: 60) == 0: return "every \(Int(m / 60)) hours"
        default: return "every \(Int(minutes)) min"
        }
    }

    var nightHours: String { String(format: "%02d:00–%02d:00", nightStartHour, nightEndHour) }

    func isNight(_ date: Date) -> Bool {
        guard nightStartHour != nightEndHour else { return false }
        let h = Calendar.current.component(.hour, from: date)
        return nightStartHour < nightEndHour ? (nightStartHour..<nightEndHour).contains(h) : h >= nightStartHour || h < nightEndHour
    }

    /// Minutes between check-in wakes at that time (0 = none).
    func wakeInterval(at date: Date) -> Double { isNight(date) ? nightWakeIntervalMinutes : wakeIntervalMinutes }

    /// When to wake from sleep next to check in with the phone (nil = don't). `backoff`: check-ins in a row that
    /// couldn't reach the relay; each doubles the interval, up to 4 hours (or the interval itself if longer).
    func nextCheckIn(after date: Date, backoff: Int = 0) -> Date? {
        // The next two times night starts or ends: the next period begins, then the one after it.
        let changes = nightStartHour == nightEndHour ? [] : [nightStartHour, nightEndHour].compactMap {
            Calendar.current.nextDate(after: date, matching: DateComponents(hour: $0, minute: 0, second: 0), matchingPolicy: .nextTime)
        }.sorted()
        let interval = wakeInterval(at: date)
        guard interval > 0 else { return changes.first { wakeInterval(at: $0) > 0 } }
        let at = date.addingTimeInterval(min(interval * pow(2, Double(min(backoff, 6))), max(interval, 240)) * 60)
        guard let change = changes.first, change < at else { return at }
        let next = wakeInterval(at: change)
        if next >= interval { return at }   // a longer interval follows: this wake is just its first
        if next > 0 { return change }       // a shorter one follows: start it on time
        return changes.dropFirst().first    // none follows: wake when this period comes back
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
    /// When the oldest background subagent or task (shell) started, if only those keep the chat working.
    let backgroundSince: Double?
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
        case .working:
            if turn == nil, let bg = backgroundSince {
                return (subagents > 0 ? "subagents " : "background task ") + AppDelegate.elapsed(since: bg)
            }
            return "working " + AppDelegate.elapsed(since: turn?.startedAt ?? startedAt)
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
    /// When we last sent the continue prompt after a usage limit, per session (retries are spaced out).
    private var lastContinue: [String: Double] = [:]
    /// Stall nudges per session: the heartbeat they were sent at and how many in a row.
    private var nudges: [String: (heartbeat: Double, at: Double, count: Int)] = [:]
    /// Chats we stopped acting on after a failed delivery: until the user resumes, or 10 minutes pass.
    @Published private(set) var blocked: [String: (reason: String, at: Double)] = [:]
    /// A "new chat" prompt waiting for the new VS Code tab to register.
    /// The queue item stays in its queue until it has been handed over, so a failure doesn't lose it.
    /// `from` is the chat whose queue holds the item; nil for a chat the phone asked for, which
    /// runs `fallback` (headless) instead of a pre-filled tab if the tab doesn't register.
    private struct PendingNewChat { let item: QueuedPrompt; let cwd: String; let openedAt: Double; let from: String?
        var fallback: ((_ cwd: String, _ text: String) -> Void)? = nil }
    private var pendingNewChat: PendingNewChat?
    /// Why the Mac should stay awake for the autopilot (a continue, nudge or queued prompt is pending).
    private(set) var keepAwakeReasons: [String] = []
    /// When the next continue after a usage limit is due, so a sleeping Mac can wake up for it.
    private(set) var nextContinueAt: Double?

    private var lastPrune: Double = 0
    /// Chats run with `claude -p`: their queue is run by HeadlessRunner with --resume once the
    /// process exits; sending to the inbox of a process about to exit could lose the prompt.
    var isHeadless: (String) -> Bool = { _ in false }

    init() {
        // Write settings added since (with their defaults), so settings.json lists every option.
        // Only add what's missing: a file that doesn't parse (a typo) or has values load() rejects stays as it is.
        let url = AutopilotSettings.url
        guard let data = try? Data(contentsOf: url) else { settings.save(); return }
        guard var onDisk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let all = (try? JSONEncoder().encode(settings)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              !Set(all.keys).isSubset(of: onDisk.keys) else { return }
        onDisk.merge(all) { old, _ in old }
        if let out = try? JSONSerialization.data(withJSONObject: onDisk, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    private static let idleSettle: Double = 5
    private static let deliveryTimeout: Double = 120
    private static let newChatTimeout: Double = 60
    private static let blockedRetry: Double = 10 * 60

    // MARK: - Registry

    static func collectSessions(stallMinutes: Double = AutopilotSettings.load().stallMinutes,
                                maxNudges: Int = AutopilotSettings.load().maxNudges) -> [AgentSession] {
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
        return groups.compactMap { key, g -> AgentSession? in
            guard let any = g.presence ?? g.turn ?? g.subs.first else { return nil }
            // A turn interrupted with Esc never fires Stop; the transcript says so.
            let turn = g.turn.flatMap { t in
                SessionInbox.lastTurnInterrupted(transcript: g.presence?.transcript, after: t.startedAt) ? nil : t
            }
            // Subagents still registered (SubagentStop removes them), silent ones too: their work isn't done. Not those
            // of a turn interrupted with Esc (stopped with it), nor any silent past the last nudge (gone without a trace).
            let interruptedAt = turn == nil ? g.turn?.startedAt : nil
            let subs = g.subs.filter { s in
                interruptedAt.map { s.startedAt < $0 } ?? true
                    && (s.openTools?.isEmpty == false || now - s.touchedAt < stallMinutes * 60 * Double(maxNudges + 1))
            }
            let actors = [turn].compactMap { $0 } + subs
            let heartbeat = actors.map(\.touchedAt).max()
            let shells = ProcessTree.longRunningShellChildren(of: any.pid, in: table, minAge: minShellAge)
            // A shell running during a Bash call is a build or tests: working, even without heartbeats. Without
            // one it is background work (a dev server, a watcher) that says nothing about the turn.
            // Markers from before tool calls were tracked (openTools nil) count any shell.
            let inTool = actors.contains { $0.openTools?.isEmpty != true }
            let silent = !(inTool && !shells.isEmpty) && heartbeat.map { now - $0 >= stallMinutes * 60 } == true
            let waiting = g.presence?.awaitingInputAt

            let state: AgentSession.State
            if turn != nil {
                if let waiting { state = .waiting(since: waiting) }
                else if silent, let heartbeat { state = .stalled(since: heartbeat) }
                else { state = .working }
            } else if let reset = g.presence?.limitResetAt {
                state = .limited(until: reset)
            } else if !subs.isEmpty {
                // The turn is over, background subagents still run: Claude goes on when they report back.
                if let waiting, waiting >= heartbeat ?? 0 { state = .waiting(since: waiting) }
                else if silent, let heartbeat { state = .stalled(since: heartbeat) }
                else { state = .working }
            } else if !shells.isEmpty {
                // The turn is over, but a background task (tests, a build) still runs: Claude picks up its result when it ends.
                state = .working
            } else {
                state = .idle
            }
            return AgentSession(id: key, agent: any.agent, session: any.session, pid: any.pid,
                                cwd: g.presence?.cwd ?? any.cwd,
                                title: SessionInbox.title(transcript: g.presence?.transcript) ?? g.presence?.title,
                                presence: g.presence, turn: turn, subagents: subs.count, lastHeartbeat: heartbeat,
                                backgroundSince: turn == nil ? (subs.map(\.startedAt) + shells.map(\.startTime)).min() : nil,
                                state: state, queue: PromptQueue.load(key))
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Loop (called from the app timer)

    func tick() {
        let now = Date().timeIntervalSince1970
        let onDisk = AutopilotSettings.load() // pick up hand edits of settings.json
        if onDisk != settings { settings = onDisk }
        var list = Self.collectSessions(stallMinutes: settings.stallMinutes, maxNudges: settings.maxNudges)
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Forget state of closed sessions.
        deliveries = deliveries.filter { byId[$0.key] != nil }
        nudges = nudges.filter { byId[$0.key] != nil }
        lastContinue = lastContinue.filter { byId[$0.key] != nil }
        blocked = blocked.filter { byId[$0.key] != nil && now - $0.value.at < Self.blockedRetry }

        for i in list.indices {
            let s = list[i]
            trackDelivery(s, now: now)
            list[i].next = act(on: s, now: now)
        }
        resolveNewChat(list, now: now)
        pruneQueues(of: byId, now: now)
        keepAwakeReasons = list.compactMap { keepAwakeReason($0, now: now) } + (pendingNewChat.map { _ in ["opening a new chat"] } ?? [])
        nextContinueAt = settings.autoContinue ? list.compactMap { continueAt($0) }.min() : nil
        sessions = list
    }

    /// When the continue prompt goes to a chat stopped by a usage limit: a minute after the reset, not sooner
    /// than minContinueInterval after the last try (a reset time in the past would retry every tick).
    private func continueAt(_ s: AgentSession) -> Double? {
        guard case .limited(let until) = s.state, s.agent == "claude", s.canReceive else { return nil }
        let at = max(until + 60, (lastContinue[s.id] ?? 0) + HeadlessRunner.minContinueInterval)
        return blocked[s.id].map { max(at, $0.at + Self.blockedRetry) } ?? at
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
        case .working:
            // Activity monitoring lets a silent turn go after 20 minutes: with a longer stallMinutes, stay up for the nudge.
            guard settings.stallNudge, s.turn != nil || s.subagents > 0, let hb = s.lastHeartbeat,
                  now - hb >= ActivityMonitor.Config().staleAfter, now - hb < settings.stallMinutes * 60 else { return nil }
            return "\(label(s)): nudge if still silent"
        case .waiting:
            return nil
        }
    }

    /// Queues of chats that are gone (closed, /clear, crashed) would never run; drop them, but say so.
    private func pruneQueues(of live: [String: AgentSession], now: Double) {
        guard now - lastPrune > 60 else { return }
        lastPrune = now
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.queue.path)) ?? []
        // Chats the phone ran headless keep their queue after the process exits (HeadlessRunner resumes them).
        let liveFiles = Set((Array(live.keys) + HeadlessRunner.knownKeys()).map { PromptQueue.url(for: $0).lastPathComponent })
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
        case .limited:
            guard settings.autoContinue else { return "usage limit (auto-continue off)" }
            guard let at = continueAt(s) else { return nil }
            if now >= at {
                // limitResetAt stays until the turn starts (the UserPromptSubmit hook clears it): if none does,
                // the delivery times out, the chat is paused for a while, and the next try comes after that.
                if deliver(settings.continuePrompt, to: s, now: now) { lastContinue[s.id] = now }
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
                // Mid-turn Claude reads it between tool calls; after the turn (background subagents) it starts one.
                if deliver(settings.statusPrompt, to: s, now: now, expectTurn: s.turn == nil) {
                    n = (since, now, n.count + 1)
                }
                nudges[s.id] = n
                return nil
            }
            nudges[s.id] = n
            return "nudge again in \(formatDuration(n.at + wait - now))"

        case .working:
            // Silent turn or background subagent: count down to the nudge (past it, a build or tests are running).
            guard settings.stallNudge, s.turn != nil || s.subagents > 0, let hb = s.lastHeartbeat else { return nil }
            let left = hb + settings.stallMinutes * 60 - now
            return left > 0 ? "nudge in \(formatDuration(left))" : nil

        case .waiting:
            return "waiting for you in the chat (no nudges)"

        case .idle:
            break
        }

        // Idle: run the queue.
        guard let item = s.queue.first else { return nil }
        guard settings.queueEnabled else { return "queue paused" }
        if isHeadless(s.id) { return "next prompt once this run ends" }
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
            guard let from = p.from else {
                if !deliver(p.item.text, to: fresh, now: now) { p.fallback?(p.cwd, p.item.text) }
                return
            }
            if deliver(p.item.text, to: fresh, now: now) {
                PromptQueue.remove(from, id: p.item.id)
            } else {
                blocked[from] = ("the new chat could not receive the prompt", now) // don't open tab after tab
            }
        } else if now - p.openedAt > Self.newChatTimeout {
            pendingNewChat = nil
            guard let from = p.from else {
                Log.write("autopilot", "new chat did not register within \(Int(Self.newChatTimeout))s — running the prompt headless instead")
                p.fallback?(p.cwd, p.item.text)
                return
            }
            if openEditor(cwd: p.cwd, prefill: p.item.text) {
                PromptQueue.remove(from, id: p.item.id)
                Log.write("autopilot", "new chat did not register within \(Int(Self.newChatTimeout))s — opened it with the prompt pre-filled instead")
            } else {
                failNewChat(from: from, now: now)
            }
        }
    }

    /// Open a new editor chat for the phone and hand it `text`; `fallback` runs if that doesn't work out.
    /// Returns false when no tab could be opened at all (or another new chat is still opening).
    func openRemoteChat(cwd: String, text: String, fallback: @escaping (_ cwd: String, _ text: String) -> Void) -> Bool {
        guard pendingNewChat == nil, openEditor(cwd: cwd, prefill: nil) else { return false }
        Log.write("autopilot", "opening a new chat in \((cwd as NSString).lastPathComponent) for “\(Self.short(text))” (from phone)")
        pendingNewChat = PendingNewChat(item: QueuedPrompt(text: text, mode: .newChat), cwd: cwd,
                                        openedAt: Date().timeIntervalSince1970, from: nil, fallback: fallback)
        return true
    }

    @discardableResult
    private func openEditor(cwd: String, prefill: String?) -> Bool {
        var c = URLComponents()
        c.scheme = settings.editorScheme
        c.host = "anthropic.claude-code"
        c.path = "/open"
        c.queryItems = [URLQueryItem(name: "cwd", value: cwd)] + (prefill.map { [URLQueryItem(name: "q", value: String($0.prefix(5000)))] } ?? [])
        // URLComponents leaves "+" alone, but the receiving end decodes it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Manual actions (Agents window, CLI)

    func sendNow(_ text: String, to id: String) {
        guard let s = Self.collectSessions(stallMinutes: settings.stallMinutes, maxNudges: settings.maxNudges).first(where: { $0.id == id }) else { return }
        blocked[id] = nil
        // Mid-turn, Claude reads the message between tool calls and no new turn starts.
        let expectTurn: Bool
        switch s.state {
        case .idle, .limited: expectTurn = true
        case .working, .stalled, .waiting: expectTurn = s.turn == nil // only background work left: it starts a new turn
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
