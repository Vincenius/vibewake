import Foundation

/// Talks to a Claude Code session through its inbox socket (cross-session messaging),
/// and reads the chat title from its transcript.
///
/// Wire format (one JSON object per line): an optional auth line with the session's
/// token, then a stream-json user message. A message to an idle session starts a new
/// turn; during a turn Claude reads it between tool calls.
enum SessionInbox {
    enum SendError: LocalizedError {
        case noSocket, unsafePath(String), connect(String), write(String)
        var errorDescription: String? {
            switch self {
            case .noSocket: return "session has no inbox socket (needs Claude Code ≥ 2.1.224 and a restarted session)"
            case .unsafePath(let p): return "refusing to use socket \(p)"
            case .connect(let e): return "connect failed: \(e)"
            case .write(let e): return "write failed: \(e)"
            }
        }
    }

    /// Starts every message we send. Claude Code hides inbox messages in the chat, so the
    /// global CLAUDE.md block (see Installer) asks Claude to repeat tagged prompts visibly.
    static let tag = "[vibewake]"

    static func send(_ text: String, to marker: Marker) throws {
        guard let path = marker.socket else { throw SendError.noSocket }
        try checkSocket(path)

        var lines: [[String: Any]] = []
        if let token = marker.token { lines.append(["type": "auth", "token": token]) }
        lines.append(["type": "user", "message": ["role": "user", "content": "\(tag) \(text)"]])
        var payload = Data()
        for line in lines {
            payload.append(try JSONSerialization.data(withJSONObject: line))
            payload.append(0x0A)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SendError.connect(String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw SendError.unsafePath(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { throw SendError.connect(String(cString: strerror(errno))) }

        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { throw SendError.write(String(cString: strerror(errno))) }
                offset += n
            }
        }
    }

    /// Only talk to a socket owned by us, in a directory Claude Code uses for inboxes.
    private static func checkSocket(_ path: String) throws {
        let resolved = (path as NSString).standardizingPath
        let dir = ((resolved as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var st = stat()
        guard dir.hasPrefix("cc-socks"), lstat(resolved, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid()
        else { throw SendError.unsafePath(path) }
    }

    // MARK: - Transcript

    /// What we know about a transcript, built incrementally: only bytes appended since
    /// the last call are read, so working chats (whose transcript changes constantly) stay cheap.
    private struct Scan {
        var offset: UInt64 = 0
        var custom: String?
        var ai: String?
        /// When the last event so far is the user interrupting (Esc): its time, else nil.
        var interruptedAt: Double?
        /// The assistant's latest text block since the last human prompt, and when it was written.
        var reply: String?
        var replyAt: Double?
    }

    private static var scans: [String: Scan] = [:]
    private static let chunkSize = 4 << 20

    /// Latest custom title (from /rename) or else AI title recorded in the transcript.
    static func title(transcript path: String?) -> String? {
        guard let path, let s = scan(path) else { return nil }
        return s.custom ?? s.ai
    }

    /// Claude's last text message in the transcript (its final answer once a turn ends).
    static func lastReply(transcript path: String?) -> (text: String, at: Double)? {
        guard let path, let s = scan(path), let text = s.reply else { return nil }
        return (text, s.replyAt ?? 0)
    }

    /// True when the transcript's last event is the user interrupting (Esc) a turn that started
    /// at `after` or later. Esc fires no Stop hook. An interrupt from before `after` belongs to an
    /// earlier turn: the current one was submitted since and just hasn't answered yet.
    static func lastTurnInterrupted(transcript path: String?, after: Double) -> Bool {
        guard let path, let at = scan(path)?.interruptedAt else { return false }
        return at >= after
    }

    private static func scan(_ path: String) -> Scan? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        var s = scans[path] ?? Scan()
        if size < s.offset { s = Scan() } // rewritten
        if size > s.offset, let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            while s.offset < size {
                try? handle.seek(toOffset: s.offset)
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                // Consume complete lines only; a partial last line is read again next time.
                guard let nl = chunk.lastIndex(of: 0x0A) else {
                    if chunk.count < chunkSize { break }
                    s.offset += UInt64(chunk.count) // a single huge line: skip it
                    continue
                }
                let lines = chunk[chunk.startIndex...nl]
                consume(lines, into: &s)
                s.offset += UInt64(lines.count)
            }
        }
        scans[path] = s
        return s
    }

    private static let customKey = Data("\"custom-title\"".utf8), aiKey = Data("\"ai-title\"".utf8)
    private static let interruptKey = Data("\"text\":\"[Request interrupted by user".utf8)
    private static let assistantKey = Data("\"type\":\"assistant\"".utf8)
    private static let userKey = Data("\"type\":\"user\"".utf8)
    private static let textBlockKey = Data("\"type\":\"text\"".utf8)
    /// Replies longer than this are cut (the phone shows replies, not whole documents).
    static let maxReply = 64 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp(of line: Data.SubSequence) -> Double? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let ts = obj["timestamp"] as? String else { return nil }
        return (iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts))?.timeIntervalSince1970
    }

    /// The joined text blocks of a user/assistant line (a plain string content counts as one block).
    private static func blockText(_ line: Data.SubSequence, role: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              obj["type"] as? String == role, obj["isMeta"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    private static func consume(_ data: Data, into s: inout Scan) {
        for line in data.split(separator: 0x0A) {
            if line.range(of: assistantKey) != nil {
                s.interruptedAt = nil
                if line.range(of: textBlockKey) != nil, let text = blockText(line, role: "assistant") {
                    s.reply = text.count > maxReply ? String(text.prefix(maxReply)) : text
                    s.replyAt = timestamp(of: line)
                }
            }
            else if line.range(of: interruptKey) != nil { s.interruptedAt = timestamp(of: line) ?? Date().timeIntervalSince1970 }
            else if line.range(of: userKey) != nil, let text = blockText(line, role: "user"), !text.isEmpty {
                // A new human prompt (tool results have no top-level text): the previous reply is answered.
                s.reply = nil; s.replyAt = nil
            }
            guard line.range(of: customKey) != nil || line.range(of: aiKey) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if obj["type"] as? String == "custom-title", let t = (obj["customTitle"] ?? obj["title"]) as? String { s.custom = t }
            if obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String { s.ai = t }
        }
    }
}
