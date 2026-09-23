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
