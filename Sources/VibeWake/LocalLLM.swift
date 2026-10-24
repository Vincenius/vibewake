import Foundation

/// LM Studio and Bionic (both by Element Labs) share one local inference engine in ~/.lmstudio.
/// Neither has hooks, so an agent counts as busy while `lms ps` reports a model generating, plus a
/// grace period that covers the tool calls between generations.
final class LocalLLMMonitor {
    /// p_comm of the app processes (their helpers are named "LM Studio Helper", "Bionic Helper").
    /// `llmster` is the headless engine `lms daemon` runs.
    static let apps: [String: String] = ["LM Studio": "LM Studio", "Bionic": "Bionic", "llmster": "LM Studio"]

    /// Busy for this long after the last generation (tool calls, MCP servers, scripts in between).
    var grace: Double = 120
    var pollInterval: Double = 5

    private var lastPoll: Double = 0
    private var polling = false
    private var generating = false
    private var lastBusyAt: Double = 0
    private var busySince: Double?

    private static let home: URL = {
        let pointer = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio-home-pointer")
        if let path = try? String(contentsOf: pointer, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio")
    }()
    private static var lms: String { home.appendingPathComponent("bin/lms").path }

    func evaluate(table: [Int32: ProcInfo], now: Double) -> [ActiveItem] {
        let running = table.values.filter { Self.apps[$0.name] != nil }
        // Only ask `lms` while an app runs: otherwise it may start the engine itself.
        guard !running.isEmpty, FileManager.default.isExecutableFile(atPath: Self.lms) else {
            generating = false; lastBusyAt = 0; busySince = nil
            return []
        }
        if lastPoll == 0 {
            // First call (also `VibeWake status`): answer right away.
            lastPoll = now
            apply(Self.poll(), at: now)
        } else if now - lastPoll >= pollInterval, !polling {
            lastPoll = now
            polling = true
            DispatchQueue.global(qos: .utility).async {
                let result = Self.poll()
                DispatchQueue.main.async {
                    self.polling = false
                    self.apply(result, at: Date().timeIntervalSince1970)
                }
            }
        }

        guard now - lastBusyAt < grace else { busySince = nil; return [] }
        let names = Array(Set(running.compactMap { Self.apps[$0.name] })).sorted()
        // The engine runs in whichever app owns it; that one's pid is in llmster-pid.lock.
        let owner = (try? String(contentsOf: Self.home.appendingPathComponent(".internal/llmster-pid.lock"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { pid in running.first { $0.pid == pid } }
        return [ActiveItem(id: "localllm", pid: (owner ?? running[0]).pid, agent: names.joined(separator: " / "), project: nil,
                           since: busySince ?? now, subagents: 0, backgroundShells: 0,
                           detail: generating ? "generating" : "between generations")]
    }

    private func apply(_ result: Bool?, at now: Double) {
        guard let result else { return } // `lms` failed: keep the last answer
        generating = result
        if result {
            if now - lastBusyAt >= grace { busySince = now }
            lastBusyAt = now
        }
    }

    /// Whether any loaded model generates or has requests queued; nil if `lms` couldn't tell.
    private static func poll() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lms)
        p.arguments = ["ps", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let models = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return models.contains { ($0["status"] as? String) == "generating" || (($0["queued"] as? Int) ?? 0) > 0 }
    }
}
