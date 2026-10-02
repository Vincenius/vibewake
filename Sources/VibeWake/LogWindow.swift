import AppKit

/// Floating log viewer. Deliberately not `NSApp.runModal`: a true modal session would
/// stop the app's timers, and with them activity monitoring and sleep control.
final class LogWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private final class EscClosableWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) { close() }
    }

    static let categories = ["All", "claude", "pi", "session", "autopilot", "state", "sleep", "system", "remote", "app"]
    private static let maxLines = 5000

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let search = NSSearchField()
    private let categoryPopup = NSPopUpButton()
    private let countLabel = NSTextField(labelWithString: "")
    private var refreshTimer: Timer?
    private var lastSignature: (Int, Date)?

    init() {
        let window = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                       styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                       backing: .buffered, defer: false)
        window.title = "VibeWake Logs"
        window.minSize = NSSize(width: 560, height: 300)
        window.level = .floating
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reload(force: true, scrollToEnd: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reload(force: false, scrollToEnd: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        search.placeholderString = "Filter"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        categoryPopup.addItems(withTitles: Self.categories)
        categoryPopup.target = self
        categoryPopup.action = #selector(filterChanged)

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyAll))
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealInFinder))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let top = NSStackView(views: [search, categoryPopup, NSView(), copy, reveal, clear])
        top.orientation = .horizontal
        top.spacing = 8
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let bottom = NSStackView(views: [countLabel, NSView(), close])
        bottom.orientation = .horizontal

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        for v in [top, scrollView, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Content

    /// Reload when the file changed (or when forced). Keeps following the end
    /// of the log if the user was already scrolled to the bottom.
    private func reload(force: Bool, scrollToEnd: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Log.url.path)
        let signature = ((attrs?[.size] as? Int) ?? 0, (attrs?[.modificationDate] as? Date) ?? .distantPast)
        if !force, let last = lastSignature, last == signature { return }
        lastSignature = signature

        let wasAtBottom = isScrolledToBottom
        let text = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(Self.maxLines)

        let category = categoryPopup.titleOfSelectedItem ?? "All"
        let query = search.stringValue.lowercased()
        let lines = all.filter { line in
            (category == "All" || line.contains("[\(category)]")) &&
            (query.isEmpty || line.lowercased().contains(query))
        }

        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        for line in lines {
            out.append(Self.styled(String(line), font: font, bold: bold))
            out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        if lines.isEmpty {
            out.append(NSAttributedString(string: all.isEmpty ? "No log entries yet." : "No entries match the filter.",
                                          attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        textView.textStorage?.setAttributedString(out)
        countLabel.stringValue = lines.count == all.count ? "\(all.count) entries" : "\(lines.count) of \(all.count) entries"

        if scrollToEnd || wasAtBottom { textView.scrollToEndOfDocument(nil) }
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.bounds.height - 20
    }

    private static func color(for category: String) -> NSColor {
        switch category {
        case "sleep": return .systemOrange
        case "state": return .systemGreen
        case "system": return .systemBlue
        case "session": return .systemPurple
        case "claude", "pi": return .systemTeal
        case "autopilot": return .systemPink
        case "remote": return .systemIndigo
        default: return .secondaryLabelColor
        }
    }

    /// `2026-09-23 09:24:44  [sleep]  message` → dim timestamp, colored tag.
    private static func styled(_ line: String, font: NSFont, bold: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let ns = line as NSString
        let open = ns.range(of: "[")
        let close = ns.range(of: "]")
        guard open.location != NSNotFound, close.location != NSNotFound, close.location > open.location else { return result }
        result.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: 0, length: open.location))
        let tagRange = NSRange(location: open.location, length: close.location - open.location + 1)
        let category = ns.substring(with: NSRange(location: open.location + 1, length: close.location - open.location - 1))
        result.addAttributes([.foregroundColor: color(for: category), .font: bold], range: tagRange)
        // Emphasise the important transitions.
        for keyword in ["ACTIVE", "IDLE", "PAUSED", "STARTED", "FINISHED", "SLEEP", "WOKE UP", "PREVENTED", "ALLOWED", "DISABLED", "RESTORED", "FAILED"] {
            let r = ns.range(of: keyword, options: [], range: NSRange(location: close.location, length: ns.length - close.location))
            if r.location != NSNotFound { result.addAttribute(.font, value: bold, range: r) }
        }
        return result
    }

    // MARK: - Actions

    @objc private func filterChanged() { reload(force: true, scrollToEnd: true) }
    func controlTextDidChange(_ obj: Notification) { filterChanged() }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.url])
    }

    @objc private func clearLog() {
        let a = NSAlert()
        a.messageText = "Clear the VibeWake log?"
        a.informativeText = "This deletes all log entries."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard let window else { return }
        a.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Log.clear()
            self?.reload(force: true, scrollToEnd: true)
        }
    }

    @objc private func closeWindow() { window?.close() }
}
