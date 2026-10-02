import AppKit

/// A chat the phone started (or continued) with `claude -p` while nobody was at the Mac.
/// Its hooks register it like any chat while it runs; once the process exits its markers are
/// gone, so we remember it here to show its reply and run follow-ups with `--resume`.
struct HeadlessChat: Codable {
    var session: String
    var cwd: String
    var transcript: String?
    var startedAt: Double
    var endedAt: Double?
    /// The `result` of the last run (fallback when the transcript can't be read).
    var lastResult: String?
    /// Why the last run failed, if it did.
    var failed: String?

    var key: String { "claude-\(session)" }
}

final class HeadlessRunner {
    private(set) var chats: [HeadlessChat] = HeadlessRunner.load()
    /// Running processes by session id ("" until the init line names the session).
    private var running: [ObjectIdentifier: (process: Process, session: String?)] = [:]
    /// Called on the main queue when a run ends: (chat, error).
    var onFinish: ((HeadlessChat, String?) -> Void)?

    static var url: URL { Paths.state.appendingPathComponent("headless.json") }
    private static let keep = 30
    private static let maxAge: Double = 7 * 24 * 3600

    static func load() -> [HeadlessChat] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HeadlessChat].self, from: data)) ?? []
    }

    /// Queue keys of remembered headless chats, so their queues survive the process exiting.
    static func knownKeys() -> Set<String> { Set(load().map(\.key)) }

    private func save() {
        let now = Date().timeIntervalSince1970
        chats = Array(chats.filter { now - ($0.endedAt ?? now) < Self.maxAge }.suffix(Self.keep))
        Paths.ensure()
        if let data = try? JSONEncoder().encode(chats) { MarkerStore.writeAtomically(data, to: Self.url) }
    }

    func isRunning(_ session: String) -> Bool { running.values.contains { $0.session == session } }

    func chat(_ key: String) -> HeadlessChat? { chats.first { $0.key == key } }

    // MARK: - Running

    /// Start a new chat (`resume == nil`) or continue one. Returns an error message on failure.
    @discardableResult
    func run(prompt: String, cwd: String, resume: String? = nil, settings: AutopilotSettings) -> String? {
        guard let claude = Self.claudeBinary(settings) else {
            return "claude binary not found (set claudePath in settings.json)"
        }
        guard FileManager.default.fileExists(atPath: cwd) else { return "project folder \(cwd) does not exist" }
        if let resume, isRunning(resume) { return "that chat is still running" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                       "--permission-mode", settings.headlessPermissionMode]
            + (resume.map { ["--resume", $0] } ?? [])
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.loginPath ?? env["PATH"]
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return "could not start claude: \(error.localizedDescription)" }
        let id = ObjectIdentifier(p)
        // One reader thread owns the stream: learns the session id early, the result at the end.
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            var result: (text: String?, error: String?) = (nil, nil)
            var announced = false
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<nl])
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if !announced, let sid = obj["session_id"] as? String {
                        announced = true
                        DispatchQueue.main.async { self?.learnSession(sid, for: id, cwd: cwd) }
                    }
                    if obj["type"] as? String == "result" {
                        let text = obj["result"] as? String
                        result = obj["is_error"] as? Bool == true ? (nil, text ?? obj["subtype"] as? String ?? "failed") : (text, nil)
                    }
                }
            }
            p.waitUntilExit()
            let status = p.terminationStatus
            let error = result.error ?? (status == 0 ? nil : "claude exited with status \(status)")
            DispatchQueue.main.async { self?.finished(id, result: result.text, error: error) }
        }
        running[id] = (p, resume)
        if let resume { learnSession(resume, for: id, cwd: cwd) }
        let what = resume.map { "resumed headless chat \($0.prefix(8))" } ?? "started headless chat"
        Log.write("remote", "\(what) in \((cwd as NSString).lastPathComponent): “\(Autopilot.short(prompt))”")
        return nil
    }

    private func learnSession(_ session: String, for id: ObjectIdentifier, cwd: String) {
        guard running[id] != nil else { return }
        running[id]?.session = session
        let now = Date().timeIntervalSince1970
        if let i = chats.firstIndex(where: { $0.session == session }) {
            chats[i].endedAt = nil
            chats[i].failed = nil
        } else {
            chats.append(HeadlessChat(session: session, cwd: cwd, transcript: Self.transcriptPath(cwd: cwd, session: session), startedAt: now))
        }
        save()
    }

    private func finished(_ id: ObjectIdentifier, result: String?, error: String?) {
        guard let run = running.removeValue(forKey: id) else { return }
        guard let session = run.session, let i = chats.firstIndex(where: { $0.session == session }) else {
            if let error { Log.write("remote", "headless chat failed before it started: \(error)") }
            return
        }
        chats[i].endedAt = Date().timeIntervalSince1970
        chats[i].lastResult = result ?? chats[i].lastResult
        chats[i].failed = error
        save()
        Log.write("remote", "headless chat \(session.prefix(8)) \(error.map { "failed: \($0)" } ?? "finished")")
        onFinish?(chats[i], error)
    }

    /// Run the next queued prompt of every remembered chat that is no longer running.
    func runQueues(live: Set<String>, settings: AutopilotSettings) {
        guard settings.queueEnabled, settings.remoteControl else { return }
        // endedAt stays nil if VibeWake restarted mid-run; no process and no markers means it is over.
        for chat in chats where chat.failed == nil && !live.contains(chat.key) && !isRunning(chat.session) {
            guard let item = PromptQueue.load(chat.key).first else { continue }
            let resume: String? = item.mode == .newChat ? nil : chat.session
            if let error = run(prompt: item.text, cwd: chat.cwd, resume: resume, settings: settings) {
                Log.write("remote", "could not run queued prompt for \(chat.session.prefix(8)): \(error)")
                if let i = chats.firstIndex(where: { $0.session == chat.session }) { chats[i].failed = error; save() }
            } else {
                PromptQueue.remove(chat.key, id: item.id)
            }
        }
    }

    /// Forget a failure so the queue runs again (Resume in the app).
    func clearFailure(_ key: String) {
        guard let i = chats.firstIndex(where: { $0.key == key }) else { return }
        chats[i].failed = nil
        save()
    }

    // MARK: - Environment

    /// Claude Code keeps transcripts in ~/.claude/projects/<cwd, non-alphanumerics → "-">/<session>.jsonl.
    static func transcriptPath(cwd: String, session: String) -> String {
        let dir = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        return Paths.home.appendingPathComponent(".claude/projects/\(dir)/\(session).jsonl").path
    }

    private static var cachedClaude: String?

    /// `claudePath` setting, else `claude` on the login shell's PATH, else the newest binary bundled with the editor extension.
    static func claudeBinary(_ settings: AutopilotSettings) -> String? {
        let fm = FileManager.default
        if !settings.claudePath.isEmpty { return fm.isExecutableFile(atPath: settings.claudePath) ? settings.claudePath : nil }
        if let c = cachedClaude, fm.isExecutableFile(atPath: c) { return c }
        if let found = shellOutput("/bin/zsh", ["-lc", "command -v claude"]), found.hasPrefix("/"), fm.isExecutableFile(atPath: found) {
            cachedClaude = found
            return found
        }
        for editor in [".vscode", ".cursor", ".vscode-insiders", ".windsurf"] {
            let dir = Paths.home.appendingPathComponent("\(editor)/extensions")
            let exts = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("anthropic.claude-code-") }
            for ext in exts.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let bin = dir.appendingPathComponent("\(ext)/resources/native-binary/claude").path
                if fm.isExecutableFile(atPath: bin) { cachedClaude = bin; return bin }
            }
        }
        return nil
    }

    /// The login shell's PATH, so tools Claude runs (node, git, …) are found like in a terminal.
    private static let loginPath: String? = shellOutput("/bin/zsh", ["-lc", "printf %s \"$PATH\""])

    private static func shellOutput(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    // MARK: - Screen

    /// Nobody can use a VS Code tab right now: screen locked, another user on the console, or lid closed without a display.
    static var nobodyAtScreen: Bool {
        if SleepController.isLidClosed && !SleepController.hasExternalDisplay { return true }
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if d["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        return d[kCGSessionOnConsoleKey as String] as? Bool == false
    }
}

/// Project folders the phone may start chats in: folders of chats seen recently, plus `remoteProjects`.
enum ProjectStore {
    static var url: URL { Paths.state.appendingPathComponent("projects.json") }
    private static let keep = 40

    static func load() -> [String: Double] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    static func remember(_ cwds: [String]) {
        var all = load()
        let now = Date().timeIntervalSince1970
        var changed = false
        for cwd in cwds where !cwd.isEmpty {
            // Only write when something is new or an hour stale, not on every tick.
            if now - (all[cwd] ?? 0) > 3600 { all[cwd] = now; changed = true }
        }
        guard changed else { return }
        let kept = all.sorted { $0.value > $1.value }.prefix(keep)
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })) {
            Paths.ensure()
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Most recently used first.
    static func list(_ settings: AutopilotSettings) -> [String] {
        let recent = load().sorted { $0.value > $1.value }.map(\.key)
        var seen = Set<String>()
        return (settings.remoteProjects + recent).filter { seen.insert($0).inserted }
    }
}
