import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Keep awake this long after the last activity, so back-to-back turns don't flap.
    static let gracePeriod: Double = 60
    /// On battery with the lid closed, give up below this charge.
    static let lowBatteryPercent = 10

    private let monitor = ActivityMonitor()
    private let sleep = SleepController()
    private let autopilot = Autopilot()
    private let reaper = SessionReaper()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var signalSources: [DispatchSourceSignal] = []

    private var items: [ActiveItem] = []
    private var lastActiveAt: Double = 0
    private var paused = UserDefaults.standard.bool(forKey: "paused")
    private var lidSupport = false
    private var lowBatteryOverride = false
    private var known: [String: (item: ActiveItem, firstSeen: Double)] = [:]
    private var lidClosed = SleepController.isLidClosed
    private enum IconState { case idle, running, windingDown, paused }
    private var iconState: IconState?
    private var logWindow: LogWindowController?
    private var agentsWindow: AgentsWindowController?
    private var autopilotHolding = false
    private var tickScheduled = false
    private lazy var remote = RemoteBridge(autopilot: autopilot)
    /// After a wake, stay up until the relay has handed over pending commands (or this deadline).
    private var checkIn: (deadline: Double, syncedAt: Double?, scheduled: Bool)?
    /// When our scheduled wake is due and what for, so a wake around then counts as "woke to check in".
    private var pendingWake: (at: Double, why: String)?
    /// On battery below this, don't wake up just to check in.
    static let checkInMinBattery = 20
    /// Check-ins in a row that timed out: the wake interval doubles with each (relay unreachable).
    private var failedCheckIns = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure()
        Log.write("app", "VibeWake started\(paused ? " (paused)" : "")")
        sleep.recoverFromPreviousRun()
        lidSupport = sleep.lidSupportAvailable
        // Keep the instructions in ~/.claude/CLAUDE.md current with this version.
        if Installer.claudeHooksInstalled, (try? Installer.installClaudeInstructions()) == true {
            Log.write("app", "Updated the VibeWake block in ~/.claude/CLAUDE.md")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        installSignalHandlers()
        observeSystemSleep()
        watchMarkerDirectory()
        DistributedNotificationCenter.default().addObserver(forName: .init("com.vibewake.showLogs"), object: nil, queue: .main) { [weak self] _ in
            self?.showLogs()
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.vibewake.showAgents"), object: nil, queue: .main) { [weak self] _ in
            self?.showAgents()
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.vibewake.autopilotTick"), object: nil, queue: .main) { [weak self] _ in
            self?.autopilot.tick()
        }
        remote.isPaused = { [weak self] in self?.paused ?? false }
        remote.setPaused = { [weak self] p in
            guard let self, p != self.paused else { return }
            self.togglePause()
        }
        remote.client.onSynced = { [weak self] in
            guard let self else { return }
            self.failedCheckIns = 0
            guard self.checkIn != nil else { return }
            self.checkIn?.syncedAt = Date().timeIntervalSince1970
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.write("app", "VibeWake quit")
        sleep.release(sleepIfLidClosed: false)
    }

    // MARK: - Core loop

    private func tick() {
        let now = Date().timeIntervalSince1970
        items = monitor.evaluate()
        logSessionChanges()
        autopilot.tick()
        reaper.update(autopilot.sessions, enabled: autopilot.settings.closeLeftovers)
        remote.update()
        checkLid()
        if finishCheckIn(now: now) { return }

        // Pending autopilot work (continue after a usage limit, a nudge, a queued prompt) needs the Mac awake too.
        let autopilotWaiting = !autopilot.keepAwakeReasons.isEmpty || checkIn != nil
        if autopilotWaiting != autopilotHolding {
            autopilotHolding = autopilotWaiting
            Log.write("state", autopilotWaiting ? "Autopilot has pending work → keeping Mac awake: " + autopilot.keepAwakeReasons.joined(separator: "; ")
                                                : "Autopilot has no pending work")
        }
        if !items.isEmpty || autopilotWaiting { lastActiveAt = now }

        let working = !items.isEmpty || autopilotWaiting || now - lastActiveAt < Self.gracePeriod
        var override = false
        var batteryInfo = ""
        if working, lidClosed, let b = SleepController.battery,
           b.onBattery, b.percent < Self.lowBatteryPercent {
            override = true
            batteryInfo = "\(b.percent)%"
        }
        if override != lowBatteryOverride {
            Log.write("sleep", override ? "Battery low (\(batteryInfo)) with lid closed — allowing sleep despite running agents"
                                        : "Battery override ended")
            lowBatteryOverride = override
        }

        let shouldHold = working && !paused && !lowBatteryOverride
        if shouldHold && !sleep.isHolding {
            Log.write("state", items.isEmpty && autopilotWaiting ? "ACTIVE — autopilot waiting → keeping Mac awake"
                               : "ACTIVE — \(items.count) session\(items.count == 1 ? "" : "s") working → keeping Mac awake")
            sleep.hold(reason: "AI agent working")
        } else if !shouldHold && sleep.isHolding {
            Log.write("state", paused ? "PAUSED — normal sleep rules apply"
                               : lowBatteryOverride ? "OVERRIDE — battery low, releasing sleep prevention"
                               : "IDLE — all AI sessions finished (grace period over) → normal sleep rules apply")
            sleep.release(sleepIfLidClosed: true)
        }
        updateIcon()
    }

    /// End the check-in once commands are handed over (plus a moment for them to start work).
    /// Returns true when it put the Mac back to sleep.
    private func finishCheckIn(now: Double) -> Bool {
        guard let c = checkIn else { return false }
        let synced = c.syncedAt.map { now - $0 > 10 } ?? false
        guard synced || now > c.deadline else { return false }
        checkIn = nil
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        failedCheckIns = synced ? 0 : failedCheckIns + 1
        Log.write("remote", synced ? "Check-in done" : "Check-in timed out (server unreachable?)")
        // Woke only to check in, nothing came up, and nobody is using the Mac: sleep right away
        // (not when a chat is about to continue after its usage limit).
        guard c.scheduled, items.isEmpty, autopilot.keepAwakeReasons.isEmpty, idle > 120,
              continueAfterLimitAt().map({ $0 - now > 120 }) ?? true else { return false }
        if sleep.isHolding { sleep.release(sleepIfLidClosed: false) }
        lastActiveAt = 0
        sleep.sleepNow()
        return true
    }

    /// Before sleeping: wake up again in a while to pick up prompts sent from the phone (more often by day
    /// than at night, see AutopilotSettings.nextCheckIn), or when a chat can continue after its usage limit.
    private func scheduleCheckInWake() {
        let now = Date()
        var wakes: [(at: Date, why: String)] = []
        // Backs off while the relay is unreachable: 2×, 4×, 8×… the interval.
        if remote.client.config != nil, !remote.client.rejected,
           let at = autopilot.settings.nextCheckIn(after: now, backoff: failedCheckIns) {
            wakes.append((at, "to check for prompts from the phone"))
        }
        if !paused, let at = continueAfterLimitAt() {
            wakes.append((max(Date(timeIntervalSince1970: at), now.addingTimeInterval(60)), "to continue after the usage limit"))
        }
        var next: (at: Double, why: String)?
        if let wake = wakes.min(by: { $0.at < $1.at }) {
            if let b = SleepController.battery, b.onBattery, b.percent < Self.checkInMinBattery {
                Log.write("sleep", "No wake scheduled \(wake.why): battery at \(b.percent)%")
            } else if sleep.scheduleWake(at: wake.at, why: wake.why) {
                next = (wake.at.timeIntervalSince1970, wake.why)
            }
        } else if remote.client.config != nil {
            Log.write("sleep", "No wake scheduled: checking for phone requests is off \(autopilot.settings.isNight(now) ? "at night" : "by day")")
        }
        pendingWake = next
        remote.client.sendSleeping(nextWakeAt: next?.at)
    }

    /// The earliest time a chat continues after its usage limit (a headless one of the phone too), if any.
    private func continueAfterLimitAt() -> Double? {
        let s = autopilot.settings
        guard s.autoContinue else { return nil }
        let headless = s.remoteControl ? remote.headless.chats.filter { $0.failed == nil }.compactMap(remote.headless.continueAt) : []
        return ([autopilot.nextContinueAt].compactMap { $0 } + headless).min()
    }

    private func startCheckIn() {
        let now = Date().timeIntervalSince1970
        let wake = pendingWake.flatMap { abs(now - $0.at) < 120 ? $0 : nil }
        pendingWake = nil
        sleep.cancelWake() // woke early (or on time): don't wake again for that one
        if let wake { Log.write("system", "Woke up \(wake.why)") }
        guard remote.client.config != nil, !remote.client.rejected else { return }
        checkIn = (deadline: now + 60, syncedAt: nil, scheduled: wake != nil)
        remote.client.reconnectNow()
    }

    private func describe(_ item: ActiveItem) -> String {
        var s = item.agent
        if let p = item.project { s += " · \(p)" }
        s += " (pid \(item.pid))"
        return s
    }

    /// Log when sessions appear / disappear, and when their subagent/shell counts change.
    private func logSessionChanges() {
        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, item) in current {
            if let (old, _) = known[id] {
                if old.subagents != item.subagents {
                    Log.write("session", "\(describe(item)): \(item.subagents) subagent\(item.subagents == 1 ? "" : "s") running")
                }
                if old.backgroundShells != item.backgroundShells {
                    Log.write("session", "\(describe(item)): \(item.backgroundShells) shell task\(item.backgroundShells == 1 ? "" : "s") running")
                }
            } else {
                var what = item.detail ?? "working"
                if item.subagents > 0 { what += ", \(item.subagents) subagents" }
                if item.backgroundShells > 0 { what += ", \(item.backgroundShells) shell tasks" }
                Log.write("session", "STARTED  \(describe(item)) — \(what)")
            }
        }
        let now = Date().timeIntervalSince1970
        for (id, old) in known where current[id] == nil {
            Log.write("session", "FINISHED \(describe(old.item)) — ran \(formatDuration(now - old.firstSeen))")
        }
        known = current.mapValues { item in
            (item, min(known[item.id]?.firstSeen ?? now, item.since))
        }
    }

    private func checkLid() {
        let closed = SleepController.isLidClosed
        guard closed != lidClosed else { return }
        lidClosed = closed
        let note = closed ? (sleep.isHolding ? " — staying awake, agents are working" : "") : ""
        Log.write("system", "Lid \(closed ? "closed" : "opened")\(note)")
    }

    private func observeSystemSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("system", "Mac is going to SLEEP" + (self.items.isEmpty ? "" : " (with \(self.items.count) session(s) still marked active)"))
            self.scheduleCheckInWake()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("system", "Mac WOKE UP")
            self?.startCheckIn()
            self?.tick()
        }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            Log.write("system", "Display went to sleep")
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Log.write("system", "Display woke up")
        }
    }

    private var graceRemaining: Int {
        guard items.isEmpty, lastActiveAt > 0 else { return 0 }
        return max(0, Int(Self.gracePeriod - (Date().timeIntervalSince1970 - lastActiveAt)))
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let state: IconState
        if paused { state = .paused }
        else if sleep.isHolding { state = items.isEmpty ? .windingDown : .running }
        else { state = .idle }
        if state != iconState {
            iconState = state
            switch state {
            case .idle:        button.image = RobotIcon.image(color: nil)
            case .running:     button.image = RobotIcon.image(color: RobotIcon.runningGreen)
            case .windingDown: button.image = RobotIcon.image(color: RobotIcon.runningGreen, alpha: 0.55)
            case .paused:      button.image = RobotIcon.image(color: nil, alpha: 0.45)
            }
        }
        button.title = items.isEmpty ? "" : " \(items.count)"
        button.toolTip = sleep.isHolding ? "VibeWake: keeping your Mac awake" : "VibeWake: idle"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        lidSupport = sleep.lidSupportAvailable

        let header: String
        if paused { header = "Paused — normal sleep rules apply" }
        else if lowBatteryOverride { header = "Battery low — allowing sleep" }
        else if !items.isEmpty { header = "Keeping awake: \(items.count) active session\(items.count == 1 ? "" : "s")" }
        else if !autopilot.keepAwakeReasons.isEmpty { header = "Keeping awake for autopilot" }
        else if sleep.isHolding { header = "Winding down… (\(graceRemaining)s)" }
        else { header = "Idle — Mac can sleep normally" }
        menu.addItem(disabled(header))

        let titles = Dictionary(autopilot.sessions.compactMap { s in s.title.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
        for item in items {
            var parts = [item.agent]
            if let p = item.project { parts.append(p) }
            if let t = titles[item.id] { parts.append("“\(t.count > 40 ? t.prefix(39) + "…" : t)”") }
            parts.append(Self.elapsed(since: item.since))
            var line = parts.joined(separator: " · ")
            var extras: [String] = []
            if item.subagents > 0 { extras.append("\(item.subagents) subagent\(item.subagents == 1 ? "" : "s")") }
            if item.backgroundShells > 0 { extras.append("\(item.backgroundShells) shell\(item.backgroundShells == 1 ? "" : "s")") }
            if let d = item.detail, extras.isEmpty { extras.append(d) }
            if !extras.isEmpty { line += "  (\(extras.joined(separator: ", ")))" }
            let mi = disabled("    " + line)
            menu.addItem(mi)
        }
        for reason in autopilot.keepAwakeReasons { menu.addItem(disabled("    " + reason)) }

        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause (allow sleep)", action: #selector(togglePause), keyEquivalent: "")
        pause.state = paused ? .on : .off
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())
        if lidSupport && (remote.client.config == nil || sleep.wakeSupportAvailable) {
            menu.addItem(disabled("Lid-closed support: ✓"))
        } else {
            menu.addItem(action(lidSupport ? "Enable Scheduled Wake (for the phone app)…" : "Enable Lid-Closed Support…", #selector(installSudoers)))
        }
        menu.addItem(disabled("Phone app: " + remoteStatusText))
        if remote.client.config != nil { menu.addItem(checkInMenu()) }
        let claude = Installer.claudeHooksInstalled ? "✓" : "–"
        let pi = Installer.piExtensionInstalled ? "✓" : "–"
        menu.addItem(disabled("Integrations: Claude Code \(claude)  pi \(pi)"))
        menu.addItem(action("Install / Update Integrations", #selector(installIntegrations)))
        let login = action("Launch at Login", #selector(toggleLogin))
        login.state = Installer.launchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let agents = action("Show Agents…", #selector(showAgents))
        agents.keyEquivalent = "a"
        menu.addItem(agents)
        let logs = action("Show Logs…", #selector(showLogs))
        logs.keyEquivalent = "l"
        menu.addItem(logs)
        menu.addItem(action("Open Marker Folder", #selector(openMarkers)))
        menu.addItem(NSMenuItem(title: "Quit VibeWake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// How often a sleeping Mac wakes to pick up what the phone sent, by day and at night.
    private func checkInMenu() -> NSMenuItem {
        let s = autopilot.settings
        let item = NSMenuItem(title: "Check for Phone Requests", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(disabled("While asleep, wake up to check:"))
        func section(_ title: String, current: Double, _ sel: Selector) {
            sub.addItem(disabled(title))
            for minutes in Set(AutopilotSettings.wakeIntervalChoices + [current]).sorted() {
                let text = AutopilotSettings.describeInterval(minutes)
                let mi = action(text.prefix(1).uppercased() + text.dropFirst(), sel)
                mi.tag = Int(minutes)
                mi.state = minutes == current ? .on : .off
                mi.indentationLevel = 1
                sub.addItem(mi)
            }
        }
        section("By day", current: s.wakeIntervalMinutes, #selector(setDayCheckIn(_:)))
        sub.addItem(.separator())
        section("At night (\(s.nightHours))", current: s.nightWakeIntervalMinutes, #selector(setNightCheckIn(_:)))
        item.submenu = sub
        return item
    }

    private var remoteStatusText: String {
        switch remote.client.status {
        case .off: return "not set up (Agents window → Remote)"
        case .connecting: return "connecting…"
        case .connected: return "connected" + (autopilot.settings.remoteControl ? "" : " (control off)")
        case .failed(let why): return "offline — \(why.prefix(50))"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        return mi
    }

    static func elapsed(since: Double) -> String {
        let s = Int(Date().timeIntervalSince1970 - since)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    // MARK: - Actions

    @objc private func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "paused")
        Log.write("app", paused ? "Paused by user" : "Resumed by user")
        tick()
    }

    @objc private func setDayCheckIn(_ sender: NSMenuItem) {
        autopilot.settings.wakeIntervalMinutes = Double(sender.tag)
        Log.write("app", "Check for phone requests by day: \(AutopilotSettings.describeInterval(Double(sender.tag)))")
    }

    @objc private func setNightCheckIn(_ sender: NSMenuItem) {
        autopilot.settings.nightWakeIntervalMinutes = Double(sender.tag)
        Log.write("app", "Check for phone requests at night: \(AutopilotSettings.describeInterval(Double(sender.tag)))")
    }

    @objc private func installSudoers() {
        // The password prompt can stay up for a while: don't stop the timers (and sleep control) meanwhile.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Installer.installSudoersInteractively() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    Log.write("app", "Lid-closed support enabled (sudoers rule installed)")
                    self.lidSupport = self.sleep.lidSupportAvailable
                    if self.sleep.isHolding { self.sleep.hold(reason: "AI agent working") } // apply disablesleep now
                case .failure(let error):
                    self.alert("Could not enable lid-closed support", error.localizedDescription)
                }
            }
        }
    }

    @objc private func installIntegrations() {
        var done: [String] = []
        do {
            try Installer.installClaudeHooks()
            done.append("Claude Code hooks → ~/.claude/settings.json")
            if try Installer.installPiExtension() { done.append("pi extension → ~/.pi/agent/extensions/vibewake") }
            Log.write("app", "Integrations installed: " + done.joined(separator: "; "))
            alert("Integrations installed", done.joined(separator: "\n") + "\n\nRestart running agent sessions (or /reload in pi) to pick them up.")
        } catch {
            alert("Installing integrations failed", error.localizedDescription)
        }
    }

    @objc private func toggleLogin() {
        do {
            try Installer.setLaunchAtLogin(!Installer.launchAtLogin)
            Log.write("app", "Launch at login \(Installer.launchAtLogin ? "enabled" : "disabled")")
        }
        catch { alert("Could not change login item", error.localizedDescription) }
    }

    @objc private func showLogs() {
        if logWindow == nil { logWindow = LogWindowController() }
        logWindow?.show()
    }

    @objc private func showAgents() {
        if agentsWindow == nil { agentsWindow = AgentsWindowController(autopilot: autopilot, remote: remote) }
        agentsWindow?.show()
    }

    @objc private func openMarkers() {
        NSWorkspace.shared.open(Paths.active)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: - Plumbing

    /// React immediately when hooks add/remove markers (the timer is the fallback).
    private func watchMarkerDirectory() {
        let fd = open(Paths.active.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        // Each hook writes a tmp file and renames it; coalesce bursts into one tick.
        src.setEventHandler { [weak self] in self?.scheduleTick() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirWatcher = src
    }

    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.tickScheduled = false
            self?.tick()
        }
    }

    /// Make sure `disablesleep` is reset when launchd or the user stops us.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                Log.write("app", "VibeWake stopped (signal \(sig))")
                self?.sleep.release(sleepIfLidClosed: false)
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
