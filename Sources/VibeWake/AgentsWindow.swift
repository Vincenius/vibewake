import AppKit
import SwiftUI

/// Floating window listing agent chats, their autopilot status and prompt queues.
final class AgentsWindowController: NSWindowController, NSWindowDelegate {
    private final class EscClosableWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) { close() }
    }

    init(autopilot: Autopilot) {
        let window = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                                       styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                       backing: .buffered, defer: false)
        window.title = "VibeWake Agents"
        window.minSize = NSSize(width: 680, height: 360)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AgentsView(autopilot: autopilot))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

private struct AgentsView: View {
    @ObservedObject var autopilot: Autopilot
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(autopilot.sessions, selection: $selection) { s in
                    SessionRow(session: s).tag(s.id)
                }
                .frame(minWidth: 300, idealWidth: 380)
                .overlay {
                    if autopilot.sessions.isEmpty {
                        Text("No agent chats open.\nClaude Code sessions appear here once a hook fires.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                }

                Group {
                    if let s = autopilot.sessions.first(where: { $0.id == selection }) {
                        SessionDetail(session: s, autopilot: autopilot)
                            .id(s.id) // fresh draft per chat
                    } else {
                        Text("Select a chat").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            SettingsBar(autopilot: autopilot)
        }
        .onAppear { selection = selection ?? autopilot.sessions.first?.id }
    }
}

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(statusColor(session.state)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle).fontWeight(.medium).lineLimit(1)
                Text([session.project ?? session.agent, session.stateText].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let next = session.next {
                    Text(next).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer()
            if !session.queue.isEmpty {
                Text("\(session.queue.count)")
                    .font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .help("\(session.queue.count) queued prompt(s)")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SessionDetail: View {
    let session: AgentSession
    @ObservedObject var autopilot: Autopilot
    @State private var draft = ""
    @State private var mode: QueuedPrompt.Mode = .sameChat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle).font(.title3).fontWeight(.semibold).textSelection(.enabled)
                Text(session.cwd ?? session.agent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 6) {
                    Circle().fill(statusColor(session.state)).frame(width: 8, height: 8)
                    Text(session.stateText)
                    if session.subagents > 0 { Text("· \(session.subagents) subagent\(session.subagents == 1 ? "" : "s")") }
                }
                .font(.callout)
                if let next = session.next { Text(next).font(.callout).foregroundStyle(.orange) }
                if !session.canReceive {
                    Text(session.agent == "claude"
                         ? "This chat has no inbox socket yet. Restart it (or send any prompt) after installing the updated hooks."
                         : "\(session.agent) chats are shown for reference; prompts can only be sent to Claude Code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Ask for status") { autopilot.sendNow(autopilot.settings.statusPrompt, to: session.id) }
                Button("Continue") { autopilot.sendNow(autopilot.settings.continuePrompt, to: session.id) }
                if autopilot.blocked[session.id] != nil {
                    Button("Resume autopilot") { autopilot.resumeQueue(session.id) }
                }
            }
            .disabled(!session.canReceive)

            Divider()
            Text("Queue").font(.headline)
            if session.queue.isEmpty {
                Text("Nothing queued. Prompts run one by one each time this chat finishes a turn.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(session.queue.enumerated()), id: \.element.id) { i, item in
                            QueueRow(item: item, index: i, count: session.queue.count) { action in
                                switch action {
                                case .up: PromptQueue.move(session.id, id: item.id, by: -1)
                                case .down: PromptQueue.move(session.id, id: item.id, by: 1)
                                case .delete: PromptQueue.remove(session.id, id: item.id)
                                }
                                autopilot.tick()
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Picker("", selection: $mode) {
                        Text("Same chat").tag(QueuedPrompt.Mode.sameChat)
                        Text("New chat").tag(QueuedPrompt.Mode.newChat)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Spacer()
                    Button("Send now") {
                        autopilot.sendNow(trimmed, to: session.id)
                        draft = ""
                    }
                    .disabled(trimmed.isEmpty || mode == .newChat || !session.canReceive)
                    Button("Add to queue") {
                        PromptQueue.add(session.id, QueuedPrompt(text: trimmed, mode: mode))
                        draft = ""
                        autopilot.tick()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmed.isEmpty)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct QueueRow: View {
    enum Action { case up, down, delete }
    let item: QueuedPrompt
    let index: Int
    let count: Int
    let perform: (Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).lineLimit(3).textSelection(.enabled)
                Text(item.mode == .sameChat ? "same chat" : "new chat").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { perform(.up) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
            Button { perform(.down) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1)
            Button { perform(.delete) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

private struct SettingsBar: View {
    @ObservedObject var autopilot: Autopilot

    var body: some View {
        HStack(spacing: 16) {
            Toggle("Continue after usage limit", isOn: $autopilot.settings.autoContinue)
            Toggle("Nudge after \(Int(autopilot.settings.stallMinutes)) min silence", isOn: $autopilot.settings.stallNudge)
            Toggle("Run queues", isOn: $autopilot.settings.queueEnabled)
            Spacer()
            Button("Settings File") { NSWorkspace.shared.activateFileViewerSelecting([AutopilotSettings.url]) }
                .help("Prompts, stall minutes and editor scheme live in settings.json")
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Helpers

private func statusColor(_ state: AgentSession.State) -> Color {
    switch state {
    case .working: return .green
    case .idle: return .gray
    case .limited: return .purple
    case .stalled: return .orange
    case .waiting: return .yellow
    }
}
