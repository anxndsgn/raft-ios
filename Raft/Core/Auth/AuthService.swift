import Foundation

/// A step-up the sign-in has to pass before it becomes a session.
struct SecondFactorPrompt: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Stage: Sendable, Hashable {
        /// Tokens were issued, then a call answered `403 second_factor_step_up_required`. Answered with
        /// `POST auth/second-factor/step-up` on those tokens (the documented step-up contract).
        case session(TokenPair, user: AuthUser?)
        /// `POST auth/login` answered `200 { secondFactorRequired: true, challenge, expiresAt, methods,
        /// maskedEmail }` and no tokens. Answered at `POST auth/second-factor/verify` with the
        /// challenge (`LoginSecondFactorContract`); the password is not kept.
        case signInChallenge(SignInChallenge)
    }

    var stage: Stage
    /// Every method the server listed or the account has (unknown ones dropped).
    var methods: [SecondFactorMethod]
    var serverMessage: String?
    /// The call that was refused, e.g. `GET servers`.
    var refusedCall: String
    /// What the server answered, for diagnostics: status, code and top-level key names (never values).
    var trigger: String = "HTTP 403 \(SecondFactorChallenge.requiredCode)"

    /// Methods the app can answer with, authenticator first. When the server named none, both.
    var usableMethods: [SecondFactorMethod] {
        if methods.isEmpty { return SecondFactorMethod.supportedInApp }
        return SecondFactorMethod.supportedInApp.filter { methods.contains($0) }
    }

    /// Only a passkey is available: the app cannot finish here (browser sign-in can).
    var passkeyOnly: Bool { usableMethods.isEmpty && methods.contains(.passkey) }

    var description: String {
        let stageName = switch stage {
        case .session: "session"
        case .signInChallenge: "sign-in challenge"
        }
        return "SecondFactorPrompt(stage: \(stageName), methods: \(methods.map(\.rawValue)), refused: \(refusedCall), trigger: \(trigger))"
    }

    var debugDescription: String { description }
}

enum SignInOutcome: Sendable, Hashable {
    case signedIn(StoredSession)
    case secondFactorRequired(SecondFactorPrompt)
    /// The code was refused (wrong, used, locked...); the prompt stays valid for another try
    /// unless the result is `.sessionFamilyRequired`.
    case secondFactorRefused(SecondFactorResult, SecondFactorPrompt)
}

enum AuthFlowError: Error, Sendable, Equatable, LocalizedError {
    case validation(String)
    case missingTokens(keys: [String])
    case browserLoginURLRejected
    case callbackInvalid
    case callbackRequestMismatch
    case browserError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .validation(let message): message
        case .missingTokens(let keys): "Sign-in answered without tokens (keys: \(keys.joined(separator: ",")))."
        case .browserLoginURLRejected: "The sign-in page address is not https."
        case .callbackInvalid: "The browser returned an unreadable sign-in result."
        case .callbackRequestMismatch: "The browser returned a result for another sign-in."
        case .browserError(let code):
            code == "access_denied" ? "Sign-in was declined in the browser." :
                code == "expired" ? "The browser sign-in expired. Try again." : "Browser sign-in failed (\(code))."
        case .cancelled: "Sign-in was cancelled."
        }
    }
}

/// A password sign-in's second step (server `services/secondFactor/signIn.ts`): an opaque,
/// single-use challenge, valid 5 minutes and for a few attempts. Redacted in descriptions.
struct SignInChallenge: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    let token: String
    let expiresAt: Date?
    /// `a***@example.com`: shown so the person recognises the account.
    let maskedEmail: String?
    /// The methods as sent: `totp`, `passkey`, `backup_code`, `recovery` (only what is set up).
    let methodNames: [String]

    var description: String { "SignInChallenge(redacted, methods: \(methodNames))" }
    var debugDescription: String { description }
}

/// The answer of `POST auth/login`, `POST auth/second-factor/verify` and `POST auth/app-login/complete`:
/// `{ user, accessToken, refreshToken, backupCodesRemaining? (verify with a backup code),
/// accountDeletion?, linkedProvider? }`, or (login with two-step verification on)
/// `{ secondFactorRequired: true, challenge, expiresAt, methods, maskedEmail }`.
struct LoginAnswer: Decodable, Sendable {
    var user: AuthUser?
    var accessToken: String?
    var refreshToken: String?
    var secondFactorRequired: Bool
    var challenge: String?
    var expiresAt: String?
    var maskedEmail: String?
    var methods: [String]
    var backupCodesRemaining: Int?
    var keys: [String]

    private enum CodingKeys: String, CodingKey {
        case user, accessToken, refreshToken, secondFactorRequired, challenge, expiresAt, maskedEmail, methods, backupCodesRemaining
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = container.lenient(.user)
        accessToken = container.lenient(.accessToken, as: String.self).flatMap { $0.isEmpty ? nil : $0 }
        refreshToken = container.lenient(.refreshToken, as: String.self).flatMap { $0.isEmpty ? nil : $0 }
        secondFactorRequired = container.lenient(.secondFactorRequired) ?? false
        challenge = container.lenient(.challenge, as: String.self).flatMap { $0.isEmpty ? nil : $0 }
        expiresAt = container.lenient(.expiresAt)
        maskedEmail = container.lenient(.maskedEmail)
        methods = container.lenient(.methods) ?? []
        backupCodesRemaining = container.flexibleInt(.backupCodesRemaining)
        keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue).sorted()
    }

    var tokens: TokenPair? {
        guard let accessToken, let refreshToken else { return nil }
        return TokenPair(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// A sign-in that stopped at the second factor (no tokens, but the flag or a challenge).
    var asksForSecondFactor: Bool { tokens == nil && (secondFactorRequired || challenge != nil) }

    /// What the server answered, for diagnostics: the flag and key names, never values.
    var diagnosticSummary: String {
        "secondFactorRequired=\(secondFactorRequired) challenge=\(challenge == nil ? "absent" : "present") keys=[\(keys.joined(separator: ","))] methods=[\(methods.joined(separator: ","))]"
    }
}

/// Answering a sign-in challenge (server `routes/auth.ts` `secondFactorVerifyHandler`, v1.33.1):
/// `POST auth/second-factor/verify { challenge, code | backupCode }` (exactly one answer; `totp` is
/// the earlier name of `code`; `webauthn` and `recovery: true` are not offered here). Unauthenticated.
/// Success is `/login`'s body plus `backupCodesRemaining` after a backup code. Refusals are
/// `{ error, code, ...extra }`: 400 `second_factor_code_invalid` / `backup_code_used` /
/// `invalid_request`, 410 `challenge_expired`, 429 `challenge_attempts_exhausted` /
/// `second_factor_locked` (`lockedUntil`, `methods`), 503 `second_factor_unavailable`.
enum LoginSecondFactorContract {
    static let path = "auth/second-factor/verify"

    static func body(challenge: String, answer: SecondFactorAnswer) -> JSONValue {
        var object: [String: JSONValue] = ["challenge": .string(challenge)]
        switch answer {
        case .totp: object["code"] = .string(answer.normalizedCode)
        case .backupCode: object["backupCode"] = .string(answer.normalizedCode)
        }
        return .object(object)
    }
}

/// A browser sign-in in progress: PKCE verifier and the request it belongs to.
struct BrowserLoginAttempt: Sendable, Hashable, CustomStringConvertible {
    let requestId: String
    let loginURL: URL
    let expiresAt: String?
    let pkce: PKCEPair
    let returnUri: String
    let callbackScheme: String

    var description: String { "BrowserLoginAttempt(redacted)" }
}

/// Sign-in, profile, servers and sign-out against one environment.
struct AuthService: Sendable {
    let client: RaftHTTPClient
    let session: SessionManager
    let appInfo: AppInfo

    // MARK: Password sign-in

    func signIn(email: String, password: String) async throws -> SignInOutcome {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            throw AuthFlowError.validation("Email and password are required.")
        }
        struct Body: Encodable { let email: String; let password: String }
        var request = try APIRequest.json("POST", "auth/login", body: Body(email: email, password: password))
        request.authenticated = false
        request.serverScope = .none
        let answer = try await client.send(request, as: LoginAnswer.self)
        if answer.asksForSecondFactor {
            guard let token = answer.challenge else { throw AuthFlowError.missingTokens(keys: answer.keys) }
            let challenge = SignInChallenge(
                token: token,
                expiresAt: answer.expiresAt.flatMap { ISO8601.parse($0) },
                maskedEmail: answer.maskedEmail,
                methodNames: answer.methods
            )
            return .secondFactorRequired(SecondFactorPrompt(
                stage: .signInChallenge(challenge),
                methods: answer.methods.compactMap(SecondFactorMethod.init(rawValue:)),
                serverMessage: nil,
                refusedCall: "POST auth/login",
                trigger: "HTTP 2xx \(answer.diagnosticSummary)"
            ))
        }
        guard let tokens = answer.tokens else { throw AuthFlowError.missingTokens(keys: answer.keys) }
        return try await finishSignIn(tokens: tokens, user: answer.user)
    }

    /// Answers `prompt` with `answer` and, once verified, completes the sign-in.
    func submitSecondFactor(_ answer: SecondFactorAnswer, for prompt: SecondFactorPrompt) async throws -> SignInOutcome {
        guard answer.isWellFormed else { throw AuthFlowError.validation(answer.formatHint) }
        switch prompt.stage {
        case .session(let tokens, let user):
            var request = try APIRequest.json("POST", "auth/second-factor/step-up", body: SecondFactorStepUpBody(answer))
            request.bearerOverride = tokens.accessToken
            request.serverScope = .none
            let response = try await client.response(for: request)
            let result = SecondFactorResult.parse(status: response.status, data: response.data)
            switch result {
            case .verified, .notEnabled:
                return try await finishSignIn(tokens: tokens, user: user)
            default:
                return .secondFactorRefused(result, prompt)
            }
        case .signInChallenge(let challenge):
            let body = LoginSecondFactorContract.body(challenge: challenge.token, answer: answer)
            var request = try APIRequest.json("POST", LoginSecondFactorContract.path, body: body)
            request.authenticated = false
            request.serverScope = .none
            let response = try await client.response(for: request)
            guard response.isSuccess else {
                return .secondFactorRefused(SecondFactorResult.parse(status: response.status, data: response.data), prompt)
            }
            guard let answer = try? RaftJSON.decode(LoginAnswer.self, from: response.data) else {
                throw APIError.decoding(path: LoginSecondFactorContract.path, detail: "unreadable login answer", traceId: response.traceId)
            }
            guard let tokens = answer.tokens else { throw AuthFlowError.missingTokens(keys: answer.keys) }
            return try await finishSignIn(tokens: tokens, user: answer.user)
        }
    }

    /// Turns issued tokens into the session: `auth/me`, then `servers`. A step-up refusal on either
    /// call becomes a prompt bound to these tokens.
    func finishSignIn(tokens: TokenPair, user: AuthUser?) async throws -> SignInOutcome {
        do {
            let me: AuthUser
            do {
                me = try await fetchUser(bearer: tokens.accessToken)
            } catch let error as APIError {
                if case .secondFactorRequired = error { throw error }
                guard let user else { throw error }
                me = user
            }
            let servers = try await fetchServers(bearer: tokens.accessToken)
            let previous = await session.current?.selectedServerId
            let stored = StoredSession(
                user: me,
                tokens: tokens,
                servers: servers,
                selectedServerId: StoredSession.resolveSelection(current: previous, servers: servers),
                signedInAt: Date()
            )
            await session.signIn(stored)
            return .signedIn(stored)
        } catch APIError.secondFactorRequired(let challenge) {
            let methods = await accountMethods(bearer: tokens.accessToken) ?? challenge.methods
            return .secondFactorRequired(SecondFactorPrompt(
                stage: .session(tokens, user: user),
                methods: methods,
                serverMessage: challenge.serverMessage,
                refusedCall: challenge.path
            ))
        }
    }

    /// The account's methods from `GET auth/second-factor/status`; nil when unavailable (flag off: 404).
    func accountMethods(bearer: String?) async -> [SecondFactorMethod]? {
        var request = APIRequest.get("auth/second-factor/status", serverScope: .none)
        request.bearerOverride = bearer
        guard let status = try? await client.send(request, as: SecondFactorStatus.self) else { return nil }
        let methods = status.availableMethods
        return methods.isEmpty ? nil : methods
    }

    // MARK: Browser sign-in (PKCE)

    func startBrowserLogin() async throws -> BrowserLoginAttempt {
        let pkce = PKCEPair.generate()
        let returnUri = appInfo.loginCallbackURI
        struct Body: Encodable { let returnUri: String; let codeChallenge: String; let codeChallengeMethod = "S256" }
        struct Answer: Decodable { let requestId: String; let loginUrl: String; let expiresAt: String? }
        var request = try APIRequest.json("POST", "auth/app-login/start", body: Body(returnUri: returnUri, codeChallenge: pkce.challenge))
        request.authenticated = false
        request.serverScope = .none
        let answer = try await client.send(request, as: Answer.self)
        guard let url = URL(string: answer.loginUrl), Self.isAllowedLoginURL(url) else {
            throw AuthFlowError.browserLoginURLRejected
        }
        return BrowserLoginAttempt(
            requestId: answer.requestId, loginURL: url, expiresAt: answer.expiresAt,
            pkce: pkce, returnUri: returnUri, callbackScheme: appInfo.callbackScheme
        )
    }

    func completeBrowserLogin(_ attempt: BrowserLoginAttempt, callbackURL: URL) async throws -> SignInOutcome {
        guard let callback = AppLoginCallback.parse(callbackURL, expectedScheme: attempt.callbackScheme) else {
            throw AuthFlowError.callbackInvalid
        }
        if let requestId = callback.requestId, requestId != attempt.requestId {
            throw AuthFlowError.callbackRequestMismatch
        }
        if let error = callback.error { throw AuthFlowError.browserError(error) }
        guard let code = callback.code else { throw AuthFlowError.callbackInvalid }
        // Two-step verification happens on the web page: approving needs a verified sign-in, and the
        // issued session inherits it. `returnUri` must equal the one sent at start.
        struct Body: Encodable { let code: String; let codeVerifier: String; let returnUri: String }
        var request = try APIRequest.json("POST", "auth/app-login/complete", body: Body(code: code, codeVerifier: attempt.pkce.verifier, returnUri: attempt.returnUri))
        request.authenticated = false
        request.serverScope = .none
        let answer = try await client.send(request, as: LoginAnswer.self)
        guard let tokens = answer.tokens else { throw AuthFlowError.missingTokens(keys: answer.keys) }
        return try await finishSignIn(tokens: tokens, user: answer.user)
    }

    /// https only; plain http only to this machine (a local development server).
    static func isAllowedLoginURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }

    // MARK: Profile and servers

    /// `GET auth/me` (a bare user; `{ user }` also accepted).
    func fetchUser(bearer: String? = nil) async throws -> AuthUser {
        var request = APIRequest.get("auth/me", serverScope: .none)
        request.bearerOverride = bearer
        let response = try await client.send(request)
        if let user = try? RaftJSON.decode(AuthUser.self, from: response.data) { return user }
        struct Wrapped: Decodable { let user: AuthUser }
        do {
            return try RaftJSON.decode(Wrapped.self, from: response.data).user
        } catch {
            throw APIError.decoding(path: "auth/me", detail: RaftHTTPClient.describe(error), traceId: response.traceId)
        }
    }

    /// `GET servers` (a bare array; `{ servers }` also accepted).
    func fetchServers(bearer: String? = nil) async throws -> [AuthServer] {
        var request = APIRequest.get("servers", serverScope: .none)
        request.bearerOverride = bearer
        let response = try await client.send(request)
        return try ListEnvelope<AuthServer>.decode(response.data, keys: ["servers", "items"], path: "servers", traceId: response.traceId)
    }

    /// Re-reads profile and servers into the stored session.
    @discardableResult
    func reloadAccount() async throws -> StoredSession? {
        let user = try await fetchUser()
        let servers = try await fetchServers()
        return await session.update { stored in
            stored.user = user
            stored.servers = servers
            stored.selectedServerId = StoredSession.resolveSelection(current: stored.selectedServerId, servers: servers)
        }
    }

    /// `POST auth/logout { refreshToken }` (best effort), then the local session is cleared.
    func signOut() async {
        if let refreshToken = await session.current?.tokens.refreshToken,
           var request = try? APIRequest.json("POST", "auth/logout", body: ["refreshToken": refreshToken]) {
            request.authenticated = false
            request.serverScope = .none
            request.timeout = 10
            _ = try? await client.response(for: request)
        }
        await session.signOut()
    }
}

extension SecondFactorAnswer {
    /// Authenticator codes are 6 digits; backup codes are any non-empty text.
    var isWellFormed: Bool {
        switch self {
        case .totp: normalizedCode.count == 6 && normalizedCode.allSatisfy(\.isASCII) && normalizedCode.allSatisfy(\.isNumber)
        case .backupCode: !normalizedCode.isEmpty && normalizedCode.count <= 64
        }
    }

    var formatHint: String {
        switch self {
        case .totp: "Enter the 6-digit code from your authenticator app."
        case .backupCode: "Enter one of your backup codes."
        }
    }
}

/// A list answered as a bare array or wrapped under one of `keys`; bad elements are skipped.
enum ListEnvelope<Element: Decodable> {
    static func decode(_ data: Data, keys: [String], path: String, traceId: String?) throws -> [Element] {
        if let list = try? RaftJSON.decode(LenientArray<Element>.self, from: data) { return list.elements }
        if let object = JSONValue.parse(data)?.objectValue {
            for key in keys {
                if let array = object[key]?.arrayValue {
                    return array.compactMap { try? $0.decode(Element.self) }
                }
            }
        }
        throw APIError.decoding(path: path, detail: "expected a list", traceId: traceId)
    }
}
