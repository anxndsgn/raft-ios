import Foundation

/// One API call, relative to the environment's API base.
struct APIRequest: Sendable {
    enum ServerScope: Sendable, Hashable {
        /// Send the selected server's id (the default; most routes need it).
        case selected
        /// Send this server's id regardless of the selection.
        case explicit(String)
        /// Send no `X-Server-Id`.
        case none
    }

    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var contentType: String?
    var headers: [String: String] = [:]
    /// Sends `Authorization` and runs the 401 refresh-and-retry.
    var authenticated = true
    var serverScope: ServerScope = .selected
    var timeout: TimeInterval = 30
    /// Sends this bearer instead of the session's and skips the refresh: the calls a sign-in makes
    /// before its tokens become the session.
    var bearerOverride: String?

    static func get(_ path: String, query: [URLQueryItem] = [], serverScope: ServerScope = .selected) -> APIRequest {
        APIRequest(method: "GET", path: path, query: query, serverScope: serverScope)
    }

    static func delete(_ path: String) -> APIRequest {
        APIRequest(method: "DELETE", path: path)
    }

    static func json<Body: Encodable>(_ method: String, _ path: String, body: Body) throws -> APIRequest {
        APIRequest(method: method, path: path, body: try RaftJSON.encode(body), contentType: "application/json")
    }

    static func post(_ path: String) -> APIRequest {
        APIRequest(method: "POST", path: path)
    }
}

struct HTTPResponse: Sendable {
    let status: Int
    /// Header names lowercased.
    let headers: [String: String]
    let data: Data

    var isSuccess: Bool { (200..<300).contains(status) }
    var traceId: String? { headers["x-trace-id"] ?? headers["x-request-id"] }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var errorBody: ServerErrorBody? { ServerErrorBody.parse(data) }

    /// `Retry-After` in seconds (delta-seconds or HTTP-date), nil when absent/unreadable.
    func retryAfterSeconds(now: Date = Date()) -> Double? {
        guard let raw = header(HeaderName.retryAfter)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// `503 {code:"rw_overloaded"}`: the read warehouse is behind; retry after `Retry-After`.
    var isReadWarehouseOverloaded: Bool {
        status == 503 && errorBody?.code == "rw_overloaded"
    }
}

/// The raw HTTP hop: builds the URLRequest with Raft's headers and performs it. No auth logic.
struct HTTPTransport: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let appInfo: AppInfo
    let environment: @Sendable () -> RaftEnvironment
    /// The network hop (URLSession in the app; scripted in tests).
    let fetch: Fetch

    init(session: URLSession, appInfo: AppInfo, environment: @escaping @Sendable () -> RaftEnvironment) {
        self.init(appInfo: appInfo, environment: environment) { request in try await session.data(for: request) }
    }

    init(appInfo: AppInfo, environment: @escaping @Sendable () -> RaftEnvironment, fetch: @escaping Fetch) {
        self.appInfo = appInfo
        self.environment = environment
        self.fetch = fetch
    }

    func perform(_ request: APIRequest, accessToken: String?, serverId: String?) async throws -> HTTPResponse {
        let url = environment().apiURL(path: request.path, query: request.query)
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        var extra = request.headers
        if let contentType = request.contentType { extra["Content-Type"] = contentType }
        let headers = RequestHeaders.build(
            appInfo: appInfo,
            accessToken: request.authenticated || request.bearerOverride != nil ? accessToken : nil,
            serverId: serverId,
            extra: extra
        )
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.transport((error as? URLError)?.localizedDescription ?? String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("not an HTTP response") }
        var lowered: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { lowered[key.lowercased()] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: lowered, data: data)
    }
}

/// What the HTTP client needs from the session: the current credentials and a single-flight
/// refresh. Implemented by `SessionManager`.
protocol CredentialProvider: Sendable {
    func currentAccessToken() async -> String?
    func selectedServerId() async -> String?
    /// Returns a fresh access token after `rejected` was answered 401. Concurrent callers share one
    /// refresh. Throws `APIError.sessionExpired` when the session cannot be refreshed.
    func refreshAccessToken(rejected: String) async throws -> String
    /// A retried request was refused again: the session is gone.
    func expireSession() async
}

/// The app's API client: headers, 503 `rw_overloaded` retry, 401 refresh-and-retry-once.
struct RaftHTTPClient: Sendable {
    let transport: HTTPTransport
    let credentials: any CredentialProvider
    /// Wait used for a 503 `rw_overloaded` without `Retry-After`, and its cap (inventory §1).
    var overloadDefaultDelay: Double = 2
    var overloadMaxDelay: Double = 10
    /// Injected so tests do not sleep.
    var sleep: @Sendable (Double) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Sends `request`; returns the 2xx response or throws `APIError`.
    @discardableResult
    func send(_ request: APIRequest) async throws -> HTTPResponse {
        let response = try await response(for: request)
        guard response.isSuccess else { throw Self.error(for: response, path: request.path) }
        return response
    }

    /// Sends `request` and returns the answer whatever its status (after the overload retry and the
    /// 401 refresh). For callers that read refusal bodies themselves (second-factor step-up).
    func response(for request: APIRequest) async throws -> HTTPResponse {
        let serverId: String?
        switch request.serverScope {
        case .selected: serverId = await credentials.selectedServerId()
        case .explicit(let id): serverId = id
        case .none: serverId = nil
        }
        if let bearer = request.bearerOverride {
            return try await performWithOverloadRetry(request, token: bearer, serverId: serverId)
        }
        var token: String?
        if request.authenticated {
            token = await credentials.currentAccessToken()
            if token == nil { throw APIError.notSignedIn }
        }
        var response = try await performWithOverloadRetry(request, token: token, serverId: serverId)
        if response.status == 401, request.authenticated, let rejected = token {
            let fresh = try await credentials.refreshAccessToken(rejected: rejected)
            response = try await performWithOverloadRetry(request, token: fresh, serverId: serverId)
            if response.status == 401 {
                await credentials.expireSession()
                throw APIError.sessionExpired
            }
        }
        return response
    }

    /// The `APIError` for a non-2xx answer: a step-up challenge, else `.http`.
    static func error(for response: HTTPResponse, path: String) -> APIError {
        let body = response.errorBody
        if let challenge = SecondFactorChallenge.parse(status: response.status, body: body, path: path) {
            return .secondFactorRequired(challenge)
        }
        return .http(status: response.status, body: body, traceId: response.traceId)
    }

    /// Sends and decodes the 2xx body as `T`.
    func send<T: Decodable>(_ request: APIRequest, as type: T.Type) async throws -> T {
        let response = try await send(request)
        do {
            return try RaftJSON.decode(T.self, from: response.data)
        } catch {
            throw APIError.decoding(path: request.path, detail: Self.describe(error), traceId: response.traceId)
        }
    }

    private func performWithOverloadRetry(_ request: APIRequest, token: String?, serverId: String?) async throws -> HTTPResponse {
        let first = try await transport.perform(request, accessToken: token, serverId: serverId)
        guard first.isReadWarehouseOverloaded else { return first }
        let delay = min(overloadMaxDelay, max(0, first.retryAfterSeconds() ?? overloadDefaultDelay))
        try await sleep(delay)
        return try await transport.perform(request, accessToken: token, serverId: serverId)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "missing \(([key] + context.codingPath).map(\.stringValue).joined(separator: "."))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "bad value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted(let context):
            return "invalid JSON \(context.debugDescription)"
        default:
            return String(describing: error)
        }
    }
}
