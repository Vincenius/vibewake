import Foundation

/// Installs / removes the agent integrations and the login item.
enum Installer {
    static let marker = "VibeWake hook"
    static let launchAgentLabel = "com.vibewake.app"
    static var launchAgentURL: URL {
        Paths.home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    // MARK: Claude Code

    static let claudeEvents: [(event: String, matcher: Bool)] = [
        ("SessionStart", false), ("SessionEnd", false),
        ("UserPromptSubmit", false), ("Stop", false),
        ("PreToolUse", true), ("PostToolUse", true),
        ("SubagentStart", false), ("SubagentStop", false),
    ]

    static var claudeSettingsURL: URL { Paths.home.appendingPathComponent(".claude/settings.json") }

    @discardableResult
    static func installClaudeHooks() throws -> Bool {
        var settings = try loadJSON(claudeSettingsURL)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command = "'\(executablePath)' hook claude"
        var changed = false

        for (event, matcher) in claudeEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if matcher { group["matcher"] = "*" }
            groups.append(group)
            if !NSArray(array: groups).isEqual(to: hooks[event] as? [Any] ?? []) { changed = true }
            hooks[event] = groups
        }
        guard changed else { return false }
        settings["hooks"] = hooks
        try backupOnce(claudeSettingsURL)
        try writeJSON(settings, to: claudeSettingsURL)
        return true
    }

    static func uninstallClaudeHooks() throws {
        var settings = try loadJSON(claudeSettingsURL)
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            let groups = (value as? [[String: Any]] ?? []).filter { !isOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSON(settings, to: claudeSettingsURL)
    }

    static var claudeHooksInstalled: Bool {
        guard let s = try? loadJSON(claudeSettingsURL), let hooks = s["hooks"] as? [String: Any] else { return false }
        return (hooks["UserPromptSubmit"] as? [[String: Any]] ?? []).contains(where: isOurs)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    // MARK: pi

    static var piAgentDir: URL { Paths.home.appendingPathComponent(".pi/agent") }
    static var piExtensionURL: URL { piAgentDir.appendingPathComponent("extensions/vibewake/index.ts") }

    @discardableResult
    static func installPiExtension() throws -> Bool {
        guard FileManager.default.fileExists(atPath: piAgentDir.path) else { return false }
        guard let src = Bundle.main.url(forResource: "pi-extension", withExtension: "ts") else {
            throw NSError(domain: "VibeWake", code: 1, userInfo: [NSLocalizedDescriptionKey: "pi-extension.ts missing from app bundle"])
        }
        try FileManager.default.createDirectory(at: piExtensionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: piExtensionURL)
        try FileManager.default.copyItem(at: src, to: piExtensionURL)
        return true
    }

    static func uninstallPiExtension() {
        try? FileManager.default.removeItem(at: piExtensionURL.deletingLastPathComponent())
    }

    static var piExtensionInstalled: Bool { FileManager.default.fileExists(atPath: piExtensionURL.path) }

    // MARK: Login item (LaunchAgent; relaunches after a crash so disablesleep gets reset)

    static var launchAtLogin: Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    static func setLaunchAtLogin(_ on: Bool) throws {
        let domain = "gui/\(getuid())"
        if on {
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false], // restart on crash, not on Quit
                "ProcessType": "Interactive",
            ]
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL)
        } else {
            shell("/bin/launchctl", ["bootout", "\(domain)/\(launchAgentLabel)"])
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    // MARK: sudoers (lid-closed support)

    static var sudoersRule: String {
        "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    }

    /// Installs /etc/sudoers.d/vibewake via an admin password prompt.
    static func installSudoersInteractively() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibewake.sudoers")
        try sudoersRule.write(to: tmp, atomically: true, encoding: .utf8)
        let script = "/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' /etc/sudoers.d/vibewake"
        let apple = "do shell script \"\(script)\" with administrator privileges"
        let status = shell("/usr/bin/osascript", ["-e", apple])
        try? FileManager.default.removeItem(at: tmp)
        if status != 0 {
            throw NSError(domain: "VibeWake", code: 2, userInfo: [NSLocalizedDescriptionKey: "Installing the sudoers rule failed or was cancelled."])
        }
    }

    // MARK: helpers

    private static func loadJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "VibeWake", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a JSON object"])
        }
        return obj
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func backupOnce(_ url: URL) throws {
        let backup = url.appendingPathExtension("vibewake-backup")
        if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
