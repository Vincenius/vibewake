import Foundation

/// Installs / removes the agent integrations and the login item.
enum Installer {
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
        ("UserPromptSubmit", false), ("Stop", false), ("StopFailure", false),
        ("PreToolUse", true), ("PostToolUse", true), ("PostToolUseFailure", true), ("PreCompact", false),
        ("SubagentStart", false), ("SubagentStop", false), ("Notification", false),
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
        if try installClaudeInstructions() { changed = true }
        guard changed else { return false }
        settings["hooks"] = hooks
        try backupOnce(claudeSettingsURL)
        try writeJSON(settings, to: claudeSettingsURL)
        return true
    }

    static func uninstallClaudeHooks() throws {
        try uninstallClaudeInstructions()
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

    // MARK: Claude Code instructions (global CLAUDE.md)

    static var claudeMemoryURL: URL { Paths.home.appendingPathComponent(".claude/CLAUDE.md") }
    private static let blockStart = "<!-- vibewake:start -->", blockEnd = "<!-- vibewake:end -->"
    static var claudeInstructions: String {
        """
        \(blockStart)
        ## VibeWake
        A message starting with `\(SessionInbox.tag)` was sent by VibeWake (the user's Mac menu bar app) on the user's behalf: a prompt they queued, or an automatic "continue" / status check. It arrives as a message from "another Claude session" and is hidden in the chat UI, so begin your reply by repeating the prompt (without the tag) as **VIBEWAKE: "<prompt>"**, then handle it as if the user typed it.
        \(blockEnd)
        """
    }

    /// Adds or refreshes our block, leaving the rest of the file alone. Returns true if the file changed.
    @discardableResult
    static func installClaudeInstructions() throws -> Bool {
        let old = (try? String(contentsOf: claudeMemoryURL, encoding: .utf8)) ?? ""
        var rest = removingBlock(from: old)
        if !rest.isEmpty && !rest.hasSuffix("\n\n") { rest += rest.hasSuffix("\n") ? "\n" : "\n\n" }
        let new = rest + claudeInstructions + "\n"
        guard new != old else { return false }
        try FileManager.default.createDirectory(at: claudeMemoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: claudeMemoryURL, atomically: true, encoding: .utf8)
        return true
    }

    static func uninstallClaudeInstructions() throws {
        guard let old = try? String(contentsOf: claudeMemoryURL, encoding: .utf8) else { return }
        let rest = removingBlock(from: old).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { try FileManager.default.removeItem(at: claudeMemoryURL) }
        else if rest + "\n" != old { try (rest + "\n").write(to: claudeMemoryURL, atomically: true, encoding: .utf8) }
    }

    private static func removingBlock(from text: String) -> String {
        guard let start = text.range(of: blockStart),
              let end = text.range(of: blockEnd, range: start.upperBound..<text.endIndex) else { return text }
        var after = text[end.upperBound...]
        if after.hasPrefix("\n") { after = after.dropFirst() }
        return String(text[..<start.lowerBound]) + after
    }

    /// Our command is `'<path>/VibeWake' hook <agent>` (older installs may lack the quotes).
    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            guard let cmd = $0["command"] as? String else { return false }
            return cmd.contains("/VibeWake' hook ") || cmd.contains("/VibeWake hook ")
        }
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
    /// The rule is written and checked as root in a root-owned temp file, so nothing running
    /// as the user can swap it between `visudo -c` and the install.
    static func installSudoersInteractively() throws {
        guard NSUserName().range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "VibeWake", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected user name \(NSUserName())"])
        }
        let rule = sudoersRule.trimmingCharacters(in: .newlines)
        let script = "T=$(/usr/bin/mktemp /tmp/vibewake.XXXXXX) && /usr/bin/printf '%s\\\\n' '\(rule)' > $T"
            + " && /usr/sbin/visudo -cf $T && /usr/bin/install -m 0440 -o root -g wheel $T /etc/sudoers.d/vibewake; S=$?; /bin/rm -f $T; exit $S"
        let apple = "do shell script \"\(script)\" with administrator privileges"
        let status = shell("/usr/bin/osascript", ["-e", apple])
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
