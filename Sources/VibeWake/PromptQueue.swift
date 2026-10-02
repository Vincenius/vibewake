import Foundation

/// A prompt waiting for its session to finish the current turn.
struct QueuedPrompt: Codable, Identifiable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        /// Send to the same chat once it is idle.
        case sameChat
        /// Open a new Claude Code chat in the same project and send it there.
        case newChat
    }
    var id = UUID()
    var text: String
    var mode: Mode
    var createdAt = Date().timeIntervalSince1970
}

/// Per-session prompt queues in ~/.vibewake/queue/<agent>-<session>.json.
enum PromptQueue {
    static func url(for key: String) -> URL {
        Paths.queue.appendingPathComponent(MarkerStore.sanitize(key) + ".json")
    }

    static func load(_ key: String) -> [QueuedPrompt] {
        guard let data = try? Data(contentsOf: url(for: key)) else { return [] }
        return (try? JSONDecoder().decode([QueuedPrompt].self, from: data)) ?? []
    }

    static func save(_ key: String, _ items: [QueuedPrompt]) {
        Paths.ensure()
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url(for: key))
        } else if let data = try? JSONEncoder().encode(items) {
            MarkerStore.writeAtomically(data, to: url(for: key))
        }
    }

    /// Read-modify-write under a lock, so the app, the CLI and the Agents window don't lose each other's changes.
    static func update(_ key: String, _ change: (inout [QueuedPrompt]) -> Void) {
        FileLock.with("queue.lock") {
            var items = load(key)
            change(&items)
            save(key, items)
        }
    }

    static func add(_ key: String, _ prompt: QueuedPrompt) {
        update(key) { $0.append(prompt) }
    }

    static func remove(_ key: String, id: UUID) {
        update(key) { $0.removeAll { $0.id == id } }
    }

    static func move(_ key: String, id: UUID, by offset: Int) {
        update(key) { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items.swapAt(i, min(max(0, i + offset), items.count - 1))
        }
    }
}
