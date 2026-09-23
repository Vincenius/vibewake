import Foundation

/// Append-only activity log at ~/.vibewake/vibewake.log, shared by the app and hook processes.
/// Each line: `2026-09-23 09:21:14  [category]  message`.
enum Log {
    static var url: URL { Paths.root.appendingPathComponent("vibewake.log") }
    static let maxBytes = 2 * 1024 * 1024

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ category: String, _ message: String) {
        Paths.ensure()
        let line = "\(formatter.string(from: Date()))  [\(category)]  \(message)\n"
        rotateIfNeeded()
        // O_APPEND keeps concurrent writers (app + hooks) from clobbering each other.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }

    private static func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// The last `count` lines, newest first.
    static func recent(_ count: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return Array(text.split(separator: "\n").suffix(count).reversed().map(String.init))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        write("app", "Log cleared")
    }
}
