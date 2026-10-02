import Foundation

/// Where the relay server is and how this Mac identifies itself there.
/// Lives in ~/.vibewake/state/remote.json (0600: it holds the machine token).
struct RemoteConfig: Codable, Equatable {
    var serverURL: String
    var machineId: String
    var token: String

    static var url: URL { Paths.state.appendingPathComponent("remote.json") }

    static func load() -> RemoteConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }

    func save() {
        Paths.ensure()
        if let data = try? JSONEncoder().encode(self) { MarkerStore.writeAtomically(data, to: Self.url) }
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }

    /// A machine id that survives re-registering (kept even after `remote off`).
    static var machineId: String {
        let file = Paths.state.appendingPathComponent("machine-id")
        if let s = try? String(contentsOf: file, encoding: .utf8), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let id = UUID().uuidString.lowercased()
        Paths.ensure()
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    static var machineName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // MARK: - REST

    enum RemoteError: LocalizedError {
        case badURL, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .badURL: return "server URL must start with https:// (or http:// for local testing)"
            case .http(let code, let body): return "server answered \(code): \(body)"
            }
        }
    }

    static func normalize(_ server: String) throws -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.scheme == "https" || u.scheme == "http", u.host != nil else { throw RemoteError.badURL }
        return s
    }

    /// Register this Mac with the relay using its setup code; saves and returns the config.
    static func register(server: String, setupCode: String) async throws -> RemoteConfig {
        let base = try normalize(server)
        let id = machineId
        let obj = try await post(base + "/api/mac/register", body: ["setupCode": setupCode, "machineId": id, "name": machineName])
        guard let token = obj["token"] as? String else { throw RemoteError.http(200, "no token in answer") }
        let config = RemoteConfig(serverURL: base, machineId: id, token: token)
        config.save()
        return config
    }

    /// A one-time code the phone scans to pair: `vibewake://pair?server=…&code=…`.
    func pairingLink() async throws -> (link: String, expiresAt: Double) {
        let obj = try await Self.post(serverURL + "/api/mac/pair", body: [:], token: token)
        guard let code = obj["code"] as? String else { throw RemoteError.http(200, "no code in answer") }
        var c = URLComponents()
        c.scheme = "vibewake"
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "server", value: serverURL), URLQueryItem(name: "code", value: code)]
        return (c.string ?? "", obj["expiresAt"] as? Double ?? 0)
    }

    private static func post(_ url: String, body: [String: Any], token: String? = nil) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw RemoteError.badURL }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw RemoteError.http(code, String(decoding: data.prefix(300), as: UTF8.self)) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// The Mac's WebSocket to the relay: sends hello, snapshots, events and acks; receives commands.
/// Reconnects with backoff; everything runs on the main queue.
final class RemoteClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    enum Status: Equatable { case off, connecting, connected, failed(String) }
    @Published private(set) var status: Status = .off

    /// Run a command: (command id, command) → (ok, error, result).
    var onCommand: ((String, [String: Any]) -> (ok: Bool, error: String?, result: Any?))?
    /// The relay has sent all pending commands.
    var onSynced: (() -> Void)?

    @Published private(set) var config: RemoteConfig?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var backoff: Double = 1
    private var reconnectWork: DispatchWorkItem?
    private var pingTimer: Timer?
    private var lastSnapshot: Data?
    private var opened = false

    /// Acks of commands already run, by id, so a command re-sent after a reconnect runs only once.
    private var done: [String: [String: Any]] = [:]
    private var doneOrder: [String] = []
    private static var doneURL: URL { Paths.state.appendingPathComponent("remote-done.json") }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        if let data = try? Data(contentsOf: Self.doneURL),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for ack in list { if let id = ack["id"] as? String { done[id] = ack; doneOrder.append(id) } }
        }
    }

    /// Pick up remote.json changes (CLI `remote setup`, the Agents window); call on every tick.
    func reloadConfig() {
        let c = RemoteConfig.load()
        guard c != config else { return }
        config = c
        disconnect()
        if c != nil { connect() } else { status = .off }
    }

    /// Reconnect right away (after waking up), instead of waiting out the backoff.
    func reconnectNow() {
        guard config != nil else { return }
        backoff = 1
        disconnect()
        connect()
    }

    private func connect() {
        guard let config, task == nil else { return }
        reconnectWork?.cancel()
        var ws = config.serverURL
        if ws.hasPrefix("https://") { ws = "wss://" + ws.dropFirst(8) } else if ws.hasPrefix("http://") { ws = "ws://" + ws.dropFirst(7) }
        guard let url = URL(string: ws + "/ws/mac") else { status = .failed("bad server URL"); return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        status = .connecting
        opened = false
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 4 << 20
        task = t
        t.resume()
        receive(on: t)
    }

    private func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lastSnapshot = nil
    }

    private func scheduleReconnect(_ reason: String) {
        disconnect()
        guard config != nil else { status = .off; return }
        status = .failed(reason)
        let delay = backoff
        backoff = min(backoff * 2, 60)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task, let config else { return }
        opened = true
        backoff = 1
        status = .connected
        Log.write("remote", "Connected to \(config.serverURL)")
        send(["type": "hello", "machineId": config.machineId, "name": RemoteConfig.machineName,
              "model": RemoteConfig.model, "appVersion": Self.appVersion])
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.send(["type": "ping"]) }
        onConnected?()
    }

    /// Called after hello, so the bridge can send a fresh snapshot.
    var onConnected: (() -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        let why = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if closeCode.rawValue == 4001 {
            // The relay doesn't know this token (Mac removed there): stop retrying.
            Log.write("remote", "Server rejected this Mac's token — set up remote access again")
            disconnect()
            status = .failed("token rejected — set up again")
            return
        }
        scheduleReconnect("closed \(closeCode.rawValue) \(why)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, let error else { return }
        if opened { Log.write("remote", "Connection lost: \(error.localizedDescription)") }
        scheduleReconnect(error.localizedDescription)
    }

    // MARK: Messages

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure: return // didCompleteWithError reconnects
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.handle(obj) }
                self.receive(on: t)
            }
        }
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "command":
            guard let id = obj["id"] as? String, let cmd = obj["cmd"] as? [String: Any] else { return }
            if let ack = done[id] { send(ack); return }
            let r = onCommand?(id, cmd) ?? (false, "not ready", nil)
            var ack: [String: Any] = ["type": "ack", "id": id, "ok": r.ok]
            if let e = r.error { ack["error"] = e }
            if let res = r.result { ack["result"] = res }
            remember(id, ack)
            send(ack)
        case "synced":
            onSynced?()
        default:
            break
        }
    }

    private func remember(_ id: String, _ ack: [String: Any]) {
        done[id] = ack
        doneOrder.append(id)
        while doneOrder.count > 300 { done[doneOrder.removeFirst()] = nil }
        // Big results (full replies) needn't survive a restart; the phone can fetch again.
        let list = doneOrder.compactMap { done[$0] }.map { ack -> [String: Any] in
            var a = ack
            a["result"] = nil
            return a
        }
        if let data = try? JSONSerialization.data(withJSONObject: list) { MarkerStore.writeAtomically(data, to: Self.doneURL) }
    }

    /// Send the snapshot if it changed since the last one sent on this connection.
    func sendSnapshot(_ snapshot: Data) {
        guard status == .connected, snapshot != lastSnapshot,
              let obj = try? JSONSerialization.jsonObject(with: snapshot) else { return }
        lastSnapshot = snapshot
        send(["type": "snapshot", "snapshot": obj])
    }

    func sendEvent(kind: String, sessionId: String, title: String, text: String) {
        send(["type": "event", "event": ["kind": kind, "sessionId": sessionId, "title": title, "text": String(text.prefix(300))]])
    }

    func sendSleeping(nextWakeAt: Double?) {
        send(["type": "sleeping", "nextWakeAt": nextWakeAt ?? NSNull()])
    }

    private func send(_ obj: [String: Any]) {
        guard let task, status == .connected,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
