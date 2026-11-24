import Foundation

/// One WebSocket carrying text frames.
protocol WebSocketConnection: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// The next text frame. Binary frames come back as "" (the client drops them). Throws once closed.
    func receive() async throws -> String
    func close()
}

protocol WebSocketConnector: Sendable {
    func connect(url: URL, headers: [String: String]) -> any WebSocketConnection
}

struct URLSessionWebSocketConnector: WebSocketConnector {
    var session: URLSession = .shared

    func connect(url: URL, headers: [String: String]) -> any WebSocketConnection {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return URLSessionWebSocketConnection(task: session.webSocketTask(with: request))
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    // @unchecked: URLSessionWebSocketTask is thread-safe; it is the only state.
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data: return ""
        @unknown default: return ""
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Where the realtime client gets its token, and its refresh after a refused handshake.
protocol RealtimeTokenSource: Sendable {
    func realtimeToken() async -> String?
    func refreshRealtimeToken(rejected: String) async throws -> String
}

extension SessionManager: RealtimeTokenSource {
    func realtimeToken() async -> String? { currentAccessToken() }

    func refreshRealtimeToken(rejected: String) async throws -> String {
        try await refreshAccessToken(rejected: rejected)
    }
}

enum RealtimeStatus: Sendable, Hashable, CustomStringConvertible {
    case idle
    case connecting(attempt: Int)
    case connected(sid: String)
    case reconnecting(after: Double, failures: Int, reason: String)
    /// Not retrying: stopped, signed out, not a member, SSO required, session expired.
    case stopped(reason: String)

    var description: String {
        switch self {
        case .idle: "idle"
        case .connecting(let attempt): "connecting (attempt \(attempt))"
        case .connected: "connected"
        case .reconnecting(let after, let failures, let reason):
            "reconnecting in \(String(format: "%.1f", after))s (\(failures) failures, \(reason))"
        case .stopped(let reason): "stopped (\(reason))"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum RealtimeError: Error, Sendable, Equatable {
    case notConnected
    case ackTimeout
    case connectionLost
}

/// Socket.IO v5 / Engine.IO v4 client over a WebSocket, for one server.
///
/// - Handshake: Engine.IO open → `40{ token, serverId, clientKind, capabilities }` (server
///   `socket/index.ts` `parseSocketHandshakeAuth`: `clientKind` ∈ web | mobile | desktop | cli;
///   `capabilities`: up to 32 strings) →
///   `40{ sid }` or `44{ message }`. A refused token is refreshed once and retried at once;
///   "not a member" and SSO stop the client.
/// - Liveness: answers server pings; the connection is dropped when nothing arrives within
///   `pingInterval + pingTimeout` (from the open packet) or no app `heartbeat` arrives within
///   `heartbeatTimeout` (the server sends one every 15 s).
/// - Reconnects with `ReconnectPolicy` backoff; `reconnectNow()` skips the wait.
/// - Sync (server `socket/syncResume.ts`): after `rooms:joined`, `sync:resume { lastSeq,
///   sinceHorizon? }` when a seq is known. `sinceHorizon` goes only on a round's first resume; the
///   `hasMore` follow-ups of that round omit it; the next round's `sinceHorizon` is the `horizon`
///   of this round's first response.
/// - Acks both ways: `emitWithAck` waits for `43<id>[...]`; server events with an id are acked.
actor RealtimeClient {
    struct Configuration: Sendable {
        var socketBaseURL: URL
        var serverId: String
        var appInfo: AppInfo
        var policy = ReconnectPolicy()
        var openTimeout: Double = 20
        var heartbeatTimeout: Double = 90
        var watchdogInterval: Double = 1
        var ackTimeout: Double = 10
        var capabilities = ["agent_activity_subscriptions_v1"]
        var clientKind = "mobile"
        var maxResumePages = 20
    }

    private enum ConnectionEnd {
        case terminal(String)
        case authRejected(token: String, message: String)
        case lost(String, wasConnected: Bool)
    }

    let config: Configuration
    private let tokens: any RealtimeTokenSource
    private let connector: any WebSocketConnector
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Double) async throws -> Void

    private var loop: Task<Void, Never>?
    private var backoff: Task<Void, Error>?
    private var connection: (any WebSocketConnection)?
    private var generation = 0
    private var sid: String?
    private var isConnected = false
    private var openInfo: EngineOpenInfo?
    private var lastInboundAt = Date.distantPast
    private var lastHeartbeatAt: Date?
    private var endReason: String?
    private var nextAckId = 0
    private var pendingAcks: [Int: CheckedContinuation<[JSONValue], Error>] = [:]
    private var joinedChannels: Set<String> = []
    private var resumePages = 0
    private var bufferedBeforeConnect: [(name: String, args: [JSONValue])] = []
    private var eventListeners: [UUID: AsyncStream<RealtimeEvent>.Continuation] = [:]
    private var statusListeners: [UUID: AsyncStream<RealtimeStatus>.Continuation] = [:]

    private(set) var status: RealtimeStatus = .idle
    private(set) var lastSeq: Int64 = 0
    private(set) var horizon: String?
    private(set) var receivedEventCount = 0
    private(set) var unknownEventCount = 0
    private(set) var droppedFrameCount = 0

    init(
        config: Configuration,
        tokens: any RealtimeTokenSource,
        connector: any WebSocketConnector = URLSessionWebSocketConnector(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.config = config
        self.tokens = tokens
        self.connector = connector
        self.now = now
        self.sleep = sleep
    }

    static func socketURL(_ base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        components.path = "/socket.io/"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        return components.url ?? base
    }

    func handshakeAuth(token: String) -> JSONValue {
        [
            "token": .string(token),
            "serverId": .string(config.serverId),
            "clientKind": .string(config.clientKind),
            "capabilities": .array(config.capabilities.map(JSONValue.string)),
        ]
    }

    // MARK: Streams

    func events() -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        eventListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeEventListener(id) } }
        return stream
    }

    func statuses() -> AsyncStream<RealtimeStatus> {
        let (stream, continuation) = AsyncStream<RealtimeStatus>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        statusListeners[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeStatusListener(id) } }
        return stream
    }

    private func removeEventListener(_ id: UUID) { eventListeners[id] = nil }
    private func removeStatusListener(_ id: UUID) { statusListeners[id] = nil }

    private func setStatus(_ value: RealtimeStatus) {
        guard value != status else { return }
        status = value
        for listener in statusListeners.values { listener.yield(value) }
    }

    private func publish(_ event: RealtimeEvent) {
        for listener in eventListeners.values { listener.yield(event) }
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { await self.runLoop() }
    }

    func stop(reason: String = "stopped") {
        loop?.cancel()
        loop = nil
        backoff?.cancel()
        backoff = nil
        generation += 1
        connection?.close()
        connection = nil
        isConnected = false
        failPendingAcks(RealtimeError.connectionLost)
        setStatus(.stopped(reason: reason))
    }

    /// Reconnect now: skips a backoff wait, or drops the current connection (e.g. after the
    /// network came back or the app returned to the foreground).
    func reconnectNow() {
        if let backoff {
            backoff.cancel()
        } else if let connection {
            endReason = "forced_reconnect"
            connection.close()
        } else if loop == nil {
            start()
        }
    }

    /// Where `sync:resume` starts after the next `rooms:joined`.
    func setResumePoint(lastSeq: Int64, horizon: String?) {
        self.lastSeq = max(0, lastSeq)
        self.horizon = horizon
    }

    // MARK: Emitting

    func emit(_ name: String, _ args: [JSONValue] = []) async throws {
        guard isConnected, let socket = connection else { throw RealtimeError.notConnected }
        try await send(SocketPacket.event(name, args), on: socket)
    }

    func emitWithAck(_ name: String, _ args: [JSONValue] = [], timeout: Double? = nil) async throws -> [JSONValue] {
        guard isConnected, let socket = connection else { throw RealtimeError.notConnected }
        let id = nextAckId
        nextAckId = nextAckId >= Int(Int32.max) ? 0 : nextAckId + 1
        let wait = timeout ?? config.ackTimeout
        let sleep = self.sleep
        let timer = Task { [weak self] in
            try? await sleep(wait)
            await self?.failAck(id, RealtimeError.ackTimeout)
        }
        defer { timer.cancel() }
        let packet = SocketPacket.event(name, args, id: id)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[JSONValue], Error>) in
            pendingAcks[id] = continuation
            Task {
                do { try await self.send(packet, on: socket) } catch { self.failAck(id, error) }
            }
        }
    }

    private func failAck(_ id: Int, _ error: Error) {
        pendingAcks.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failPendingAcks(_ error: Error) {
        let pending = pendingAcks
        pendingAcks = [:]
        for continuation in pending.values { continuation.resume(throwing: error) }
    }

    func joinChannel(_ channelId: String) async {
        joinedChannels.insert(channelId)
        try? await emit(SocketEventName.joinChannel, [.string(channelId)])
    }

    func leaveChannel(_ channelId: String) async {
        joinedChannels.remove(channelId)
        try? await emit(SocketEventName.leaveChannel, [.string(channelId)])
    }

    /// `sync:horizon` (acked): the server's current sync horizon, also kept for the next resume.
    func requestSyncHorizon() async throws -> String? {
        let reply = try await emitWithAck(SocketEventName.syncHorizon, [], timeout: 10)
        let value = reply.first?["horizon"]
        let text = value?.stringValue ?? value?.int64Value.map(String.init)
        if let text { horizon = text }
        return text
    }

    private func send(_ packet: SocketPacket, on socket: any WebSocketConnection) async throws {
        try await socket.send(EnginePacket.message(packet.encoded).encoded)
    }

    // MARK: Connection loop

    private func runLoop() async {
        var failures = 0
        var refreshedForAuth = false
        while !Task.isCancelled {
            setStatus(.connecting(attempt: failures + 1))
            let end = await runConnection()
            if Task.isCancelled { break }
            let reason: String
            switch end {
            case .terminal(let why):
                setStatus(.stopped(reason: why))
                loop = nil
                return
            case .authRejected(let token, let message):
                if !refreshedForAuth {
                    refreshedForAuth = true
                    do {
                        _ = try await tokens.refreshRealtimeToken(rejected: token)
                        continue
                    } catch APIError.sessionExpired {
                        setStatus(.stopped(reason: "session_expired"))
                        loop = nil
                        return
                    } catch {
                        // Could not refresh now: back off and try again.
                    }
                }
                reason = "auth: \(message)"
                failures += 1
            case .lost(let why, let wasConnected):
                if wasConnected {
                    failures = 0
                    refreshedForAuth = false
                }
                reason = why
                failures += 1
            }
            if Task.isCancelled { break }
            let delay = config.policy.delay(failures: failures)
            setStatus(.reconnecting(after: delay, failures: failures, reason: reason))
            let sleep = self.sleep
            let wait = Task { try await sleep(delay) }
            backoff = wait
            _ = try? await wait.value
            backoff = nil
        }
    }

    private func runConnection() async -> ConnectionEnd {
        guard let token = await tokens.realtimeToken(), !token.isEmpty else { return .terminal("signed_out") }
        generation += 1
        let current = generation
        let headers = RequestHeaders.build(appInfo: config.appInfo, accessToken: nil, serverId: nil)
        let socket = connector.connect(url: Self.socketURL(config.socketBaseURL), headers: headers)
        connection = socket
        sid = nil
        isConnected = false
        openInfo = nil
        endReason = nil
        lastInboundAt = now()
        lastHeartbeatAt = nil
        resumePages = 0
        bufferedBeforeConnect = []
        let watchdog = Task { [weak self] in await self?.watch(generation: current, socket: socket) }
        defer {
            watchdog.cancel()
            socket.close()
            if generation == current {
                connection = nil
                isConnected = false
                failPendingAcks(RealtimeError.connectionLost)
            }
        }
        do {
            while true {
                let frame = try await socket.receive()
                guard generation == current else { return .lost("superseded", wasConnected: false) }
                lastInboundAt = now()
                if let end = try await handle(frame: frame, token: token, socket: socket) { return end }
            }
        } catch {
            return .lost(endReason ?? "socket_closed", wasConnected: isConnected)
        }
    }

    private func watch(generation watched: Int, socket: any WebSocketConnection) async {
        while !Task.isCancelled {
            try? await sleep(config.watchdogInterval)
            guard generation == watched, !Task.isCancelled else { return }
            if let reason = overdueReason() {
                endReason = reason
                socket.close()
                return
            }
        }
    }

    private func overdueReason() -> String? {
        let time = now()
        if let info = openInfo {
            if time.timeIntervalSince(lastInboundAt) > info.pingInterval + info.pingTimeout { return "ping_timeout" }
        } else if time.timeIntervalSince(lastInboundAt) > config.openTimeout {
            return "open_timeout"
        }
        if isConnected, config.heartbeatTimeout > 0, let heartbeat = lastHeartbeatAt,
           time.timeIntervalSince(heartbeat) > config.heartbeatTimeout {
            return "heartbeat_timeout"
        }
        return nil
    }

    private func handle(frame: String, token: String, socket: any WebSocketConnection) async throws -> ConnectionEnd? {
        guard let packet = EnginePacket.parse(frame) else {
            droppedFrameCount += 1
            return nil
        }
        switch packet {
        case .open(let info):
            openInfo = info
            try await send(SocketPacket.connect(auth: handshakeAuth(token: token)), on: socket)
        case .ping(let payload):
            try await socket.send(EnginePacket.pong(payload).encoded)
        case .close:
            return .lost("engine_close", wasConnected: isConnected)
        case .message(let text):
            return try await handleSocket(text, token: token, socket: socket)
        case .pong, .noop, .upgrade:
            break
        }
        return nil
    }

    private func handleSocket(_ text: String, token: String, socket: any WebSocketConnection) async throws -> ConnectionEnd? {
        guard let packet = SocketPacket.parse(text), packet.namespace == "/" else {
            droppedFrameCount += 1
            return nil
        }
        switch packet.kind {
        case .connect:
            let newSid = packet.data?["sid"]?.stringValue ?? ""
            sid = newSid
            isConnected = true
            lastHeartbeatAt = now()
            setStatus(.connected(sid: newSid))
            for channelId in joinedChannels.sorted() {
                try await send(SocketPacket.event(SocketEventName.joinChannel, [.string(channelId)]), on: socket)
            }
            let buffered = bufferedBeforeConnect
            bufferedBeforeConnect = []
            for event in buffered { try await dispatch(name: event.name, args: event.args, socket: socket) }
        case .connectError:
            switch SocketHandshakeError.classify(packet.data) {
            case .notMember: return .terminal("not_member")
            case .ssoRequired: return .terminal("sso_required")
            case .authRejected(let message): return .authRejected(token: token, message: message)
            case .other(let message): return .lost("connect_error: \(message)", wasConnected: false)
            }
        case .disconnect:
            return .lost("server_disconnect", wasConnected: isConnected)
        case .event:
            guard let name = packet.eventName else {
                droppedFrameCount += 1
                return nil
            }
            if let id = packet.id {
                try await send(SocketPacket.ack(id: id, [["socketId": .string(sid ?? "")]]), on: socket)
            }
            if isConnected {
                try await dispatch(name: name, args: packet.arguments, socket: socket)
            } else {
                bufferedBeforeConnect.append((name, packet.arguments))
            }
        case .ack:
            if let id = packet.id, let continuation = pendingAcks.removeValue(forKey: id) {
                continuation.resume(returning: packet.arguments)
            }
        case .binaryEvent, .binaryAck:
            // Raft sends no binary attachments; counted, not decoded.
            droppedFrameCount += 1
        }
        return nil
    }

    private func dispatch(name: String, args: [JSONValue], socket: any WebSocketConnection) async throws {
        receivedEventCount += 1
        if !SocketEventName.serverWireEvents.contains(name) { unknownEventCount += 1 }
        let event = RealtimeEvent.decode(name: name, args: args)
        switch event {
        case .roomsJoined:
            resumePages = 0
            try await resume(socket)
        case .messageNew(let message), .messageUpdated(let message):
            if let seq = message.seq { lastSeq = max(lastSeq, seq) }
        case .syncResume(let response):
            let pageMax = response.messages.compactMap(\.seq).max() ?? 0
            if response.horizonReset {
                lastSeq = response.currentSeq
            } else if response.hasMore {
                lastSeq = max(lastSeq, pageMax)
            } else {
                lastSeq = max(lastSeq, response.currentSeq, pageMax)
            }
            // The round's first response sets the next round's horizon; follow-ups don't.
            if resumePages <= 1, let value = response.horizon { horizon = value }
            if response.hasMore, resumePages < config.maxResumePages { try await resume(socket) }
        case .heartbeat:
            lastHeartbeatAt = now()
        default:
            break
        }
        publish(event)
    }

    private func resume(_ socket: any WebSocketConnection) async throws {
        // A client with no seq yet loads over REST; there is nothing to resume.
        guard lastSeq > 0 else { return }
        resumePages += 1
        var payload: [String: JSONValue] = ["lastSeq": .number(Double(lastSeq))]
        if resumePages == 1, let horizon { payload["sinceHorizon"] = .string(horizon) }
        try await send(SocketPacket.event(SocketEventName.syncResume, [.object(payload)]), on: socket)
    }
}
