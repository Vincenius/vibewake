import AppKit

let args = CommandLine.arguments

func printErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

switch args.count > 1 ? args[1] : "" {
case "hook":
    // Called by agent hooks: `VibeWake hook claude|codex` with JSON on stdin.
    HookCommand.run(agent: args.count > 2 ? args[2] : "claude")

case "install":
    do {
        if try Installer.installClaudeHooks() { print("✓ Claude Code hooks installed in ~/.claude/settings.json") }
        else { print("✓ Claude Code hooks already up to date") }
        if try Installer.installPiExtension() { print("✓ pi extension installed in ~/.pi/agent/extensions/vibewake") }
        try Installer.setLaunchAtLogin(true)
        print("✓ Launch at login enabled")
        exit(0)
    } catch {
        printErr("install failed: \(error.localizedDescription)")
        exit(1)
    }

case "uninstall":
    try? Installer.uninstallClaudeHooks()
    Installer.uninstallPiExtension()
    try? Installer.setLaunchAtLogin(false)
    print("✓ Removed Claude hooks, pi extension and login item")
    exit(0)

case "logs":
    // Ask the running app to open its log window.
    DistributedNotificationCenter.default().postNotificationName(.init("com.vibewake.showLogs"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)

case "agents":
    DistributedNotificationCenter.default().postNotificationName(.init("com.vibewake.showAgents"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)

case "sessions":
    for s in Autopilot.collectSessions() {
        let queue = s.queue.isEmpty ? "" : "  [\(s.queue.count) queued]"
        print("\(s.session.prefix(8))  \(s.agent)  \(s.project ?? "?")  \(s.displayTitle)  (\(s.stateText))\(s.canReceive ? "" : "  no inbox")\(queue)")
    }
    exit(0)

case "send", "queue":
    // VibeWake send <session> <text…>
    // VibeWake queue <session> [--new-chat] <text…>
    // <session> is a session-id prefix or part of the chat title.
    var rest = Array(args.dropFirst(2))
    let newChat = rest.contains("--new-chat")
    rest.removeAll { $0 == "--new-chat" }
    guard rest.count >= 2 else {
        printErr("usage: VibeWake \(args[1]) <session-id-prefix|title> \(args[1] == "queue" ? "[--new-chat] " : "")<text…>")
        exit(2)
    }
    let needle = rest[0].lowercased()
    let text = rest.dropFirst().joined(separator: " ")
    let matches = Autopilot.collectSessions().filter {
        $0.session.lowercased().hasPrefix(needle) || ($0.title?.lowercased().contains(needle) ?? false)
    }
    guard matches.count == 1, let s = matches.first else {
        printErr(matches.isEmpty ? "no session matches “\(rest[0])” (see `VibeWake sessions`)"
                                 : "“\(rest[0])” matches \(matches.count) sessions — be more specific")
        exit(1)
    }
    if args[1] == "queue" {
        PromptQueue.add(s.id, QueuedPrompt(text: text, mode: newChat ? .newChat : .sameChat))
        DistributedNotificationCenter.default().postNotificationName(.init("com.vibewake.autopilotTick"), object: nil, userInfo: nil, deliverImmediately: true)
        print("✓ queued for \(s.displayTitle) (\(s.queue.count + 1) in queue)")
        exit(0)
    }
    do {
        guard let presence = s.presence else { throw SessionInbox.SendError.noSocket }
        try SessionInbox.send(text, to: presence)
        Log.write("autopilot", "\(s.project ?? s.agent) · \(s.displayTitle) ← “\(Autopilot.short(text))” (from CLI)")
        print("✓ sent to \(s.displayTitle)")
        exit(0)
    } catch {
        printErr("send failed: \(error.localizedDescription)")
        exit(1)
    }

case "status":
    let items = ActivityMonitor().evaluate()
    print(items.isEmpty ? "idle" : "active: " + items.map { "\($0.agent)\($0.project.map { " (\($0))" } ?? "")" }.joined(separator: ", "))
    exit(0)

default:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
