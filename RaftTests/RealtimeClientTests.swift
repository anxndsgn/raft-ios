import Foundation
import Testing
@testable import Raft

/// A scripted WebSocket: the test pushes server frames and reads what the client sent.
final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    struct Closed: Error {}

    private let lock = NSLock()
    private var buffer: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private var outbound: [String] = []
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    var sent: [String] { lock.withLock { outbound } }
    var isClosed: Bool { lock.withLock { closed } }

    func push(_ frame: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: frame)
        } else {
            buffer.append(frame)
            lock.unlock()
        }
    }

    func send(_ text: String) async throws {
        try lock.withLock {
            if closed { throw Closed() }
            outbound.append(text)
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let frame = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: Closed())
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: Closed())
    }

    /// Waits until the client sent a frame matching `predicate`.
    func waitForSent(_ predicate: @escaping @Sendable (String) -> Bool) async -> String? {
        _ = await eventually { self.sent.contains(where: predicate) }
        return sent.first(where: predicate)
    }
}

final class FakeConnector: WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeSocket] = []

    var sockets: [FakeSocket] { lock.withLock { made } }

    func connect(url: URL, headers: [String: String]) -> any WebSocketConnection {
        let socket = FakeSocket(url: url, headers: headers)
        lock.withLock { made.append(socket) }
        return socket
    }

    func socket(_ index: Int) async -> FakeSocket? {
        _ = await eventually { self.sockets.count > index }
        let all = sockets
        return all.count > index ? all[index] : nil
    }
}

actor FakeTokens: RealtimeTokenSource {
    var token: String? = "tok-1"
    var refreshes = 0
    var refreshError: APIError?

    func realtimeToken() async -> String? { token }

    func refreshRealtimeToken(rejected: String) async throws -> String {
        refreshes += 1
        if let refreshError { throw refreshError }
        token = "tok-\(refreshes + 1)"
        return token!
    }

    func failRefresh(with error: APIError) { refreshError = error }
}

struct RealtimeClientTests {
    private func makeClient(_ connector: FakeConnector, _ tokens: FakeTokens, heartbeatTimeout: Double = 90) -> RealtimeClient {
        var config = RealtimeClient.Configuration(socketBaseURL: URL(string: "https://api.raft.build")!, serverId: "srv-1", appInfo: testAppInfo)
        config.heartbeatTimeout = heartbeatTimeout
        config.watchdogInterval = 0.02
        return RealtimeClient(config: config, tokens: tokens, connector: connector, sleep: { seconds in
            // Backoff and watchdog waits are shortened so tests stay fast.
            try await Task.sleep(nanoseconds: UInt64(min(seconds, 0.02) * 1_000_000_000))
        })
    }

    private static let open = #"0{"sid":"eio-1","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#

    private func connect(_ client: RealtimeClient, _ connector: FakeConnector, index: Int = 0) async throws -> FakeSocket {
        let socket = try #require(await connector.socket(index))
        socket.push(Self.open)
        let auth = try #require(await socket.waitForSent { $0.hasPrefix("40") })
        #expect(auth.hasPrefix("40{"))
        socket.push(#"40{"sid":"sio-1"}"#)
        #expect(await eventually { await client.status.isConnected })
        return socket
    }

    @Test func handshakeSendsAuthAndConnects() async throws {
        let connector = FakeConnector()
        let tokens = FakeTokens()
        let client = makeClient(connector, tokens)
        await client.start()
        let socket = try await connect(client, connector)
        #expect(socket.url.absoluteString == "wss://api.raft.build/socket.io/?EIO=4&transport=websocket")
        #expect(socket.headers["X-Raft-Client-Platform"] == "ios")
        let auth = try #require(socket.sent.first { $0.hasPrefix("40") })
        let payload = try #require(JSONValue.parse(String(auth.dropFirst(2))))
        #expect(payload["token"] == "tok-1")
        #expect(payload["serverId"] == "srv-1")
        #expect(payload["clientKind"] == "mobile")
        #expect(payload["capabilities"] == ["agent_activity_subscriptions_v1"])
        #expect(payload.objectValue?.keys.sorted() == ["capabilities", "clientKind", "serverId", "token"], "only fields the server reads")
        #expect(await client.status == .connected(sid: "sio-1"))
        await client.stop()
        #expect(socket.isClosed)
    }

    @Test func answersPingsAndAcksServerEvents() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector, FakeTokens())
        await client.start()
        let socket = try await connect(client, connector)
        socket.push("2")
        #expect(await socket.waitForSent { $0 == "3" } != nil)
        socket.push(#"428["notification:desktop",{"id":"n1"}]"#)
        #expect(await socket.waitForSent { $0 == #"438[{"socketId":"sio-1"}]"# } != nil)
        await client.stop()
    }

    @Test func roomsJoinedResumesFromLastSeqAndFollowsPages() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector, FakeTokens())
        await client.setResumePoint(lastSeq: 40, horizon: "777")
        let events = await client.events()
        await client.start()
        let socket = try await connect(client, connector)
        socket.push(#"42["rooms:joined",{}]"#)
        let resume = try #require(await socket.waitForSent { $0.hasPrefix(#"42["sync:resume""#) })
        #expect(resume == #"42["sync:resume",{"lastSeq":40,"sinceHorizon":"777"}]"#)
        socket.push(#"42["sync:resume:response",{"messages":[{"id":"m41","seq":41},{"id":"m42","seq":42}],"currentSeq":50,"hasMore":true,"horizon":"800","horizonReset":false}]"#)
        #expect(await socket.waitForSent { $0 == #"42["sync:resume",{"lastSeq":42}]"# } != nil)
        socket.push(#"42["sync:resume:response",{"messages":[],"currentSeq":50,"hasMore":false,"horizon":"801"}]"#)
        #expect(await eventually { await client.lastSeq == 50 })
        socket.push(#"42["message:new",{"id":"m60","seq":60,"channelId":"c1","content":"hi"}]"#)
        #expect(await eventually { await client.lastSeq == 60 })
        let names = await collect(events) { $0.count == 4 }.map(\.name)
        #expect(names == ["rooms:joined", "sync:resume:response", "sync:resume:response", "message:new"])
        #expect(await client.horizon == "800", "the round's first response sets the next horizon")
        await client.stop()
    }

    @Test func freshClientDoesNotResume() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector, FakeTokens())
        await client.start()
        let socket = try await connect(client, connector)
        socket.push(#"42["rooms:joined",{}]"#)
        socket.push(#"42["heartbeat",{"seq":3,"ts":1}]"#)
        #expect(await eventually { await client.receivedEventCount == 2 })
        #expect(!socket.sent.contains { $0.contains("sync:resume") })
        await client.stop()
    }

    @Test func emitWithAckResolvesAndTimesOut() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector, FakeTokens())
        await client.start()
        let socket = try await connect(client, connector)
        async let horizon = client.requestSyncHorizon()
        let request = try #require(await socket.waitForSent { $0.hasPrefix("420[") })
        #expect(request == #"420["sync:horizon"]"#)
        socket.push(#"430[{"horizon":"12345"}]"#)
        #expect(try await horizon == "12345")
        await #expect(throws: RealtimeError.ackTimeout) {
            _ = try await client.emitWithAck("no:answer", [], timeout: 0.05)
        }
        await client.stop()
        await #expect(throws: RealtimeError.notConnected) { try await client.emit("x") }
    }

    @Test func joinedChannelsAreRejoinedAfterReconnect() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector, FakeTokens())
        await client.start()
        let first = try await connect(client, connector)
        await client.joinChannel("c7")
        #expect(await first.waitForSent { $0 == #"42["join:channel","c7"]"# } != nil)
        first.close()
        let second = try await connect(client, connector, index: 1)
        #expect(await second.waitForSent { $0 == #"42["join:channel","c7"]"# } != nil)
        await client.leaveChannel("c7")
        #expect(await second.waitForSent { $0 == #"42["leave:channel","c7"]"# } != nil)
        await client.stop()
    }

    @Test func rejectedTokenRefreshesOnceAndReconnectsImmediately() async throws {
        let connector = FakeConnector()
        let tokens = FakeTokens()
        let client = makeClient(connector, tokens)
        await client.start()
        let first = try #require(await connector.socket(0))
        first.push(Self.open)
        _ = await first.waitForSent { $0.hasPrefix("40") }
        first.push(#"44{"message":"Invalid or expired token"}"#)
        let second = try await connect(client, connector, index: 1)
        let auth = try #require(second.sent.first { $0.hasPrefix("40") })
        #expect(JSONValue.parse(String(auth.dropFirst(2)))?["token"] == "tok-2")
        #expect(await tokens.refreshes == 1)
        await client.stop()
    }

    @Test func expiredSessionStopsTheClient() async throws {
        let connector = FakeConnector()
        let tokens = FakeTokens()
        await tokens.failRefresh(with: .sessionExpired)
        let client = makeClient(connector, tokens)
        await client.start()
        let socket = try #require(await connector.socket(0))
        socket.push(Self.open)
        _ = await socket.waitForSent { $0.hasPrefix("40") }
        socket.push(#"44{"message":"Authentication required"}"#)
        #expect(await eventually { await client.status == .stopped(reason: "session_expired") })
    }

    @Test func notAMemberIsTerminal() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector, FakeTokens())
        await client.start()
        let socket = try #require(await connector.socket(0))
        socket.push(Self.open)
        _ = await socket.waitForSent { $0.hasPrefix("40") }
        socket.push(#"44{"message":"Not a member of this server"}"#)
        #expect(await eventually { await client.status == .stopped(reason: "not_member") })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(connector.sockets.count == 1, "no reconnect after a terminal refusal")
    }

    @Test func missingHeartbeatDropsAndReconnects() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector, FakeTokens(), heartbeatTimeout: 0.1)
        let statuses = await client.statuses()
        await client.start()
        let first = try await connect(client, connector)
        #expect(await eventually { first.isClosed })
        let seen = await collect(statuses) { items in
            items.contains { if case .reconnecting = $0 { true } else { false } }
        }
        let reasons: [String] = seen.compactMap { if case .reconnecting(_, _, let reason) = $0 { reason } else { nil } }
        #expect(reasons.first == "heartbeat_timeout")
        #expect(await connector.socket(1) != nil)
        await client.stop()
    }

    @Test func signedOutClientStops() async {
        let connector = FakeConnector()
        let tokens = FakeTokens()
        let client = makeClient(connector, tokens)
        await tokensSignOut(tokens)
        await client.start()
        #expect(await eventually { await client.status == .stopped(reason: "signed_out") })
        #expect(connector.sockets.isEmpty)
    }

    private func tokensSignOut(_ tokens: FakeTokens) async {
        await tokens.clear()
    }
}

extension FakeTokens {
    func clear() { token = nil }
}
