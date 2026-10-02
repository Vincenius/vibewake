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
        // O_APPEND keeps concurrent writers (app + hooks) from clobbering each other;
        // the lock makes sure only one of them rotates.
        var fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
        if rotateIfNeeded(fd) {
            close(fd)
            fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            flock(fd, LOCK_EX)
        }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }

    /// Rotate if the file behind `fd` is too big and still the current log (another writer may have rotated it).
    private static func rotateIfNeeded(_ fd: Int32) -> Bool {
        var open = stat(), current = stat()
        guard fstat(fd, &open) == 0, open.st_size > maxBytes,
              stat(url.path, &current) == 0, current.st_ino == open.st_ino else { return open.st_size > maxBytes }
        return rename(url.path, url.appendingPathExtension("1").path) == 0
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
