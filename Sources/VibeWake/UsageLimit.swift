import Foundation

/// Recognizes usage-limit failures and finds out when the limit resets.
enum UsageLimit {
    /// "You've hit your session limit · resets 3:40am (Europe/Berlin)", "Claude AI usage limit reached|<epoch>",
    /// "5-hour limit reached".
    static func isLimitMessage(_ text: String?) -> Bool {
        guard let t = text?.lowercased() else { return false }
        return ["usage limit", "limit reached", "rate limit"].contains { t.contains($0) }
            || (t.contains("hit your") && t.contains("limit"))
    }

    /// The reset time Claude Code stored with the latest usage-limit error in a transcript
    /// (`quotaLimits.resetsAt` of the API error message), if that error is from the last `within` seconds.
    static func resetTime(transcript path: String?, now: Double = Date().timeIntervalSince1970, within: Double = 10 * 60) -> Double? {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let key = Data("\"quotaLimits\"".utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: key) != nil {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let quota = obj["quotaLimits"] as? [String: Any],
                  quota["status"] as? String ?? "rejected" == "rejected",
                  let at = (quota["resetsAt"] as? NSNumber)?.doubleValue else { continue }
            if let ts = obj["timestamp"] as? String, let t = iso.date(from: ts)?.timeIntervalSince1970, now - t > within { return nil }
            return at > 1e12 ? at / 1000 : at
        }
        return nil
    }

    /// The reset time in a limit message: "resets 3:40am (Europe/Berlin)", "resets 5pm",
    /// "resets Oct 5, 3pm (Europe/Berlin)", or the older "…usage limit reached|1759420800".
    static func resetTime(in text: String?, now: Date = Date()) -> Double? {
        guard let text else { return nil }
        if let r = text.range(of: #"\|\d{10}\b"#, options: .regularExpression) { return Double(text[r].dropFirst()) }
        let pattern = #"resets\s+(?:([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?\s*(?:\(([^)]+)\))?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }

        guard var hour = group(3).flatMap(Int.init), hour <= 23 else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        if let ampm = group(5)?.lowercased() {
            guard (1...12).contains(hour) else { return nil }
            if ampm.hasPrefix("p") && hour != 12 { hour += 12 }
            if ampm.hasPrefix("a") && hour == 12 { hour = 0 }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = group(6).flatMap { TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) } ?? .current
        var match = DateComponents(hour: hour, minute: minute, second: 0)
        if let month = group(1), let day = group(2).flatMap(Int.init) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            guard let i = f.shortMonthSymbols.map({ $0.lowercased() }).firstIndex(of: String(month.lowercased().prefix(3))) else { return nil }
            match.month = i + 1
            match.day = day
        }
        // The next such time: a reset lies ahead (a few minutes of slack for one that just passed).
        return cal.nextDate(after: now.addingTimeInterval(-10 * 60), matching: match, matchingPolicy: .nextTime)?.timeIntervalSince1970
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
