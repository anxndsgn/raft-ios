import Foundation

/// What changed about the session, for UI and the realtime client.
enum SessionEvent: Sendable, Equatable {
    case signedIn(StoredSession)
    case updated(StoredSession)
    case signedOut
    /// The refresh token was refused (or a retried request was refused again). Sign in again.
    case expired
}

/// `POST auth/refresh` and its classification.
protocol TokenRefreshing: Sendable {
    /// New tokens for `refreshToken`. Throws `TokenRefreshError`.
    func refresh(refreshToken: String, attemptId: String, installationId: String) async throws -> TokenPair
}

enum TokenRefreshError: Error, Sendable, Equatable {
    /// The server refused the refresh token (400/401/403): the session is over.
    case rejected(status: Int, code: String?)
    /// No answer: the request may or may not have reached the server.
    case ambiguous(String)
    /// The server answered but could not refresh now (429/5xx, unreadable 2xx). Keep the session.
    case unavailable(status: Int, code: String?)
}

/// The network side of the refresh: `POST auth/refresh { refreshToken }` with the attempt and
/// installation headers → `{ accessToken, refreshToken }` (the refresh token rotates).
struct HTTPTokenRefresher: TokenRefreshing {
    let transport: HTTPTransport

    private struct Body: Encodable { let refreshToken: String }
    private struct Answer: Decodable {
        let accessToken: String
        let refreshToken: String?
    }

    func refresh(refreshToken: String, attemptId: String, installationId: String) async throws -> TokenPair {
        var request = try APIRequest.json("POST", "auth/refresh", body: Body(refreshToken: refreshToken))
        request.authenticated = false
        request.serverScope = .none
        request.timeout = 15
        request.headers[HeaderName.refreshAttemptId] = attemptId
        request.headers[HeaderName.installationId] = installationId
        let response: HTTPResponse
        do {
            response = try await transport.perform(request, accessToken: nil, serverId: nil)
        } catch let error as APIError {
            if case .transport(let detail) = error { throw TokenRefreshError.ambiguous(detail) }
            throw error
        }
        switch response.status {
        case 200..<300:
            guard let answer = try? RaftJSON.decode(Answer.self, from: response.data), !answer.accessToken.isEmpty else {
                throw TokenRefreshError.unavailable(status: response.status, code: "auth_refresh_contract_mismatch")
            }
            // Rotation: the answer's refresh token replaces ours; an answer without one keeps it.
            let next = answer.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
            return TokenPair(accessToken: answer.accessToken, refreshToken: next)
        case 400, 401, 403:
            throw TokenRefreshError.rejected(status: response.status, code: response.errorBody?.code)
        default:
            throw TokenRefreshError.unavailable(status: response.status, code: response.errorBody?.code)
        }
    }
}

/// The session for one environment: loaded from and saved to the Keychain, the source of the
/// access token for every request, and the single-flight token refresh.
///
/// Refresh rules:
/// - Concurrent 401s share one `POST auth/refresh` per refresh token.
/// - A 401 for a token that was already replaced returns the newer token without a refresh.
/// - No answer (the request may have rotated the token server-side): one replay with the same
///   `X-Slock-Auth-Refresh-Attempt-Id`, which the server answers from its receipt.
/// - Refused refresh: the session is cleared and `.expired` is published.
actor SessionManager: CredentialProvider {
    let environment: RaftEnvironment.Kind
    private let store: SessionVault
    private let refresher: any TokenRefreshing
    private let installationId: String
    private var session: StoredSession?
    private var inFlight: (refreshToken: String, id: UUID, task: Task<String, Error>)?
    private var listeners: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    /// Refresh attempts made (tests and diagnostics).
    private(set) var refreshCount = 0

    init(environment: RaftEnvironment.Kind, store: SessionVault, refresher: any TokenRefreshing) {
        self.environment = environment
        self.store = store
        self.refresher = refresher
        installationId = store.installationId()
        session = store.load(environment)
    }

    var current: StoredSession? { session }

    func events() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func publish(_ event: SessionEvent) {
        for continuation in listeners.values { continuation.yield(event) }
    }

    func signIn(_ newSession: StoredSession) {
        session = newSession
        persist()
        publish(.signedIn(newSession))
    }

    /// Changes the stored session (servers, selection, profile) and saves it.
    @discardableResult
    func update(_ change: @Sendable (inout StoredSession) -> Void) -> StoredSession? {
        guard var value = session else { return nil }
        change(&value)
        session = value
        persist()
        publish(.updated(value))
        return value
    }

    func selectServer(_ id: String) -> StoredSession? {
        update { session in
            if session.servers.contains(where: { $0.id == id }) { session.selectedServerId = id }
        }
    }

    func signOut() {
        inFlight?.task.cancel()
        inFlight = nil
        session = nil
        store.clear(environment)
        publish(.signedOut)
    }

    private func persist() {
        guard let session else { return }
        // A failed Keychain write keeps the in-memory session for this launch.
        try? store.save(session, environment: environment)
    }

    // MARK: CredentialProvider

    func currentAccessToken() -> String? { session?.tokens.accessToken }

    func selectedServerId() -> String? { session?.selectedServerId }

    func refreshAccessToken(rejected: String) async throws -> String {
        guard let session else { throw APIError.sessionExpired }
        if session.tokens.accessToken != rejected {
            // Another caller already refreshed past the rejected token.
            return session.tokens.accessToken
        }
        let refreshToken = session.tokens.refreshToken
        if let inFlight, inFlight.refreshToken == refreshToken {
            return try await inFlight.task.value
        }
        let id = UUID()
        let task = Task { try await self.runRefresh(refreshToken: refreshToken) }
        inFlight = (refreshToken, id, task)
        defer { if inFlight?.id == id { inFlight = nil } }
        return try await task.value
    }

    private func runRefresh(refreshToken: String) async throws -> String {
        let attemptId = RefreshAttemptId.generate()
        var attempt = 0
        while true {
            attempt += 1
            refreshCount += 1
            do {
                let pair = try await refresher.refresh(refreshToken: refreshToken, attemptId: attemptId, installationId: installationId)
                return try apply(pair, replacing: refreshToken)
            } catch TokenRefreshError.ambiguous(let detail) {
                // The request may have rotated the token; replay the same attempt once.
                if attempt < 2, !Task.isCancelled { continue }
                throw APIError.transport(detail)
            } catch TokenRefreshError.rejected {
                expire(ifRefreshToken: refreshToken)
                throw APIError.sessionExpired
            } catch TokenRefreshError.unavailable(let status, let code) {
                throw APIError.http(status: status, body: code.flatMap { ServerErrorBody.coded($0) }, traceId: nil)
            }
        }
    }

    private func apply(_ pair: TokenPair, replacing refreshToken: String) throws -> String {
        guard var value = session, value.tokens.refreshToken == refreshToken else {
            // Signed out or signed in again meanwhile: these tokens belong to no current session.
            throw APIError.sessionExpired
        }
        value.tokens = pair
        session = value
        persist()
        publish(.updated(value))
        return pair.accessToken
    }

    private func expire(ifRefreshToken refreshToken: String) {
        guard session?.tokens.refreshToken == refreshToken else { return }
        session = nil
        store.clear(environment)
        publish(.expired)
    }

    func expireSession() {
        guard session != nil else { return }
        session = nil
        store.clear(environment)
        publish(.expired)
    }
}

extension ServerErrorBody {
    /// A body carrying only `code` (for errors synthesized from a refusal code).
    static func coded(_ code: String) -> ServerErrorBody? {
        ServerErrorBody.parse(Data(JSONValue.object(["code": .string(code)]).jsonString().utf8))
    }
}
