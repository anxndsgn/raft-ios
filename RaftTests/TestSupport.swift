import Foundation
@testable import Raft

let testAppInfo = AppInfo(version: "1.2.3", build: "45", buildType: "Debug", osVersion: "26.0", callbackScheme: "raft-debug")

/// A scripted HTTP server: routes by "METHOD path" (path relative to the API base, no query),
/// records every request. Safe to use from parallel tests (one instance per test).
final class FakeServer: @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
        var failure: URLError.Code?

        static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: body, headers: headers)
        }

        static func transportFailure(_ code: URLError.Code = .networkConnectionLost) -> Reply {
            Reply(status: 0, body: "", failure: code)
        }
    }

    struct Recorded: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data?

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var json: JSONValue? { body.flatMap { JSONValue.parse($0) } }
    }

    typealias Handler = @Sendable (Recorded, Int) -> Reply

    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private var counts: [String: Int] = [:]
    private var recorded: [Recorded] = []
    let environment: RaftEnvironment
    /// Delay before answering (to overlap concurrent requests).
    var latency: Double = 0

    init(environment: RaftEnvironment = .production) {
        self.environment = environment
    }

    /// Answers `route` ("GET servers") with `handler(request, callIndex)`.
    func on(_ route: String, _ handler: @escaping Handler) {
        lock.withLock { routes[route] = handler }
    }

    /// Answers `route` with the replies in order; the last one repeats.
    func on(_ route: String, replies: [Reply]) {
        on(route) { _, index in replies[min(index, replies.count - 1)] }
    }

    func on(_ route: String, _ reply: Reply) {
        on(route, replies: [reply])
    }

    var requests: [Recorded] { lock.withLock { recorded } }

    func requests(_ route: String) -> [Recorded] {
        requests.filter { "\($0.method) \($0.path)" == route }
    }

    func count(_ route: String) -> Int { requests(route).count }

    var transport: HTTPTransport {
        let environment = environment
        return HTTPTransport(appInfo: testAppInfo, environment: { environment }) { [self] request in
            try await self.handle(request)
        }
    }

    private func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let base = environment.apiBaseURL.path
        var path = url.path
        if path.hasPrefix(base) { path = String(path.dropFirst(base.count)) }
        while path.hasPrefix("/") { path.removeFirst() }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let record = Recorded(
            method: request.httpMethod ?? "GET",
            path: path,
            query: query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
        let route = "\(record.method) \(path)"
        let (handler, index): (Handler?, Int) = lock.withLock {
            recorded.append(record)
            let index = counts[route, default: 0]
            counts[route] = index + 1
            return (routes[route], index)
        }
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        let reply = handler?(record, index) ?? .json(404, #"{"error":"no route \#(route)"}"#)
        if let failure = reply.failure { throw URLError(failure) }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

/// Recorded sleeps, no waiting.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    var sleeps: [Double] { lock.withLock { values } }

    var sleep: @Sendable (Double) async throws -> Void {
        { [self] seconds in self.lock.withLock { self.values.append(seconds) } }
    }
}

struct TestCore {
    let server: FakeServer
    let secure: InMemorySecureStore
    let session: SessionManager
    let client: RaftHTTPClient
    let auth: AuthService
    let api: RaftAPI
    let sleeps: SleepRecorder

    init(server: FakeServer = FakeServer(), session existing: StoredSession? = nil) {
        self.server = server
        secure = InMemorySecureStore()
        let store = SessionStore(secure: secure)
        if let existing { try? store.save(existing, environment: server.environment.kind) }
        let transport = server.transport
        session = SessionManager(environment: server.environment.kind, store: store, refresher: HTTPTokenRefresher(transport: transport))
        sleeps = SleepRecorder()
        var client = RaftHTTPClient(transport: transport, credentials: session)
        client.sleep = sleeps.sleep
        self.client = client
        auth = AuthService(client: client, session: session, appInfo: testAppInfo)
        api = RaftAPI(client: client)
    }
}

func sampleSession(access: String = "access-1", refresh: String = "refresh-1", servers: [AuthServer]? = nil) -> StoredSession {
    let list = servers ?? [AuthServer(id: "srv-1", name: "One"), AuthServer(id: "srv-2", name: "Two")]
    return StoredSession(
        user: AuthUser(id: "u-1", email: "person@example.invalid", name: "Person", profileSetupCompletedAt: "2026-01-01T00:00:00Z"),
        tokens: TokenPair(accessToken: access, refreshToken: refresh),
        servers: list,
        selectedServerId: list.first?.id,
        signedInAt: Date(timeIntervalSince1970: 0)
    )
}

/// Polls `condition` (every 5 ms, up to `timeout`).
func eventually(timeout: Double = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

let userJSON = #"{"id":"u-1","email":"person@example.invalid","name":"Person","displayName":"P","profileSetupCompletedAt":"2026-01-01T00:00:00Z"}"#
let serversJSON = #"[{"id":"srv-1","name":"One","role":"owner","hideHumansFromMembers":false},{"id":"srv-2","name":"Two"}]"#

/// Collects elements from `stream` until `done` says stop, or `timeout` passes (so a broken
/// expectation fails the test instead of hanging the suite).
func collect<T: Sendable>(
    _ stream: AsyncStream<T>,
    timeout: Double = 3,
    until done: @escaping @Sendable ([T]) -> Bool
) async -> [T] {
    await withTaskGroup(of: [T]?.self) { group in
        group.addTask {
            var items: [T] = []
            for await item in stream {
                items.append(item)
                if done(items) { break }
            }
            return items
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}
