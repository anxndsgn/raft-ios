import Foundation
import Testing
@testable import Raft

struct AuthServiceTests {
    private let loginJSON = #"{"user":{"id":"u-1","email":"person@example.invalid"},"accessToken":"access-1","refreshToken":"refresh-1"}"#
    private let stepUpJSON = #"{"error":"Verify it's you","code":"second_factor_step_up_required","methods":["totp","backup_code","passkey"]}"#

    @Test func passwordSignInStoresSessionAndSelectsFirstServer() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, loginJSON))
        core.server.on("GET auth/me", .json(200, userJSON))
        core.server.on("GET servers", .json(200, serversJSON))
        let outcome = try await core.auth.signIn(email: " person@example.invalid ", password: "pw")
        guard case .signedIn(let session) = outcome else { Issue.record("not signed in: \(outcome)"); return }
        #expect(session.user.displayName == "P")
        #expect(session.servers.map(\.id) == ["srv-1", "srv-2"])
        #expect(session.selectedServerId == "srv-1")
        #expect(!session.user.needsProfileSetup)
        let login = try #require(core.server.requests("POST auth/login").first)
        #expect(login.json == ["email": "person@example.invalid", "password": "pw"])
        #expect(login.header("Authorization") == nil)
        #expect(login.header("X-Server-Id") == nil)
        #expect(core.server.requests("GET servers").first?.header("Authorization") == "Bearer access-1")
        #expect(SessionStore(secure: core.secure).load(.production)?.tokens.accessToken == "access-1")
        #expect(await core.session.current?.user.id == "u-1")
    }

    @Test func blankProfileSetupMeansSetupNeeded() throws {
        let user = try RaftJSON.decode(AuthUser.self, from: Data(#"{"id":"u","profileSetupCompletedAt":"  "}"#.utf8))
        #expect(user.needsProfileSetup)
        let missing = try RaftJSON.decode(AuthUser.self, from: Data(#"{"id":"u","name":5}"#.utf8))
        #expect(missing.needsProfileSetup)
        #expect(missing.name == nil, "mistyped field is dropped")
    }

    @Test func stepUpAfterTokensUsesStatusMethodsThenFinishes() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, loginJSON))
        core.server.on("GET auth/me", .json(200, userJSON))
        core.server.on("GET servers", replies: [.json(403, stepUpJSON), .json(200, serversJSON)])
        core.server.on("GET auth/second-factor/status", .json(200, #"{"enabled":true,"methods":{"totp":true,"passkeys":0,"backupCodesRemaining":5}}"#))
        core.server.on("POST auth/second-factor/step-up", .json(200, #"{"verified":true,"backupCodesRemaining":5}"#))

        let first = try await core.auth.signIn(email: "person@example.invalid", password: "pw")
        guard case .secondFactorRequired(let prompt) = first else { Issue.record("no prompt: \(first)"); return }
        #expect(prompt.methods == [.totp, .backupCode], "methods come from second-factor status")
        #expect(prompt.refusedCall == "servers")
        guard case .session = prompt.stage else { Issue.record("expected session stage"); return }
        #expect(await core.session.current == nil, "not a session until verified")
        #expect(core.server.requests("GET auth/second-factor/status").first?.header("Authorization") == "Bearer access-1")

        let second = try await core.auth.submitSecondFactor(.totp("123 456"), for: prompt)
        guard case .signedIn(let session) = second else { Issue.record("not signed in: \(second)"); return }
        #expect(session.servers.count == 2)
        let stepUp = try #require(core.server.requests("POST auth/second-factor/step-up").first)
        #expect(stepUp.json == ["code": "123456"])
        #expect(stepUp.header("Authorization") == "Bearer access-1")
        #expect(await core.session.current?.tokens.accessToken == "access-1")
    }

    @Test func stepUpFallsBackToChallengeMethodsWhenStatusIsOff() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, loginJSON))
        core.server.on("GET auth/me", .json(403, stepUpJSON))
        core.server.on("GET auth/second-factor/status", .json(404, #"{"error":"Not found"}"#))
        let outcome = try await core.auth.signIn(email: "a@b.c", password: "pw")
        guard case .secondFactorRequired(let prompt) = outcome else { Issue.record("no prompt"); return }
        #expect(prompt.methods == [.totp, .backupCode, .passkey])
        #expect(prompt.usableMethods == [.totp, .backupCode])
        #expect(prompt.refusedCall == "auth/me")
    }

    @Test func refusedCodesKeepThePrompt() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, loginJSON))
        core.server.on("GET auth/me", .json(200, userJSON))
        core.server.on("GET servers", .json(403, stepUpJSON))
        core.server.on("GET auth/second-factor/status", .json(404, "{}"))
        core.server.on("POST auth/second-factor/step-up", replies: [
            .json(400, #"{"error":"Invalid code","code":"second_factor_code_invalid"}"#),
            .json(400, #"{"code":"backup_code_used"}"#),
        ])
        guard case .secondFactorRequired(let prompt) = try await core.auth.signIn(email: "a@b.c", password: "pw") else {
            Issue.record("no prompt"); return
        }
        let wrong = try await core.auth.submitSecondFactor(.totp("000000"), for: prompt)
        #expect(wrong == .secondFactorRefused(.codeInvalid, prompt))
        let used = try await core.auth.submitSecondFactor(.backupCode("abcd-efgh"), for: prompt)
        #expect(used == .secondFactorRefused(.backupCodeUsed, prompt))
        #expect(core.server.requests("POST auth/second-factor/step-up").last?.json == ["backupCode": "abcd-efgh"])
        await #expect(throws: AuthFlowError.self) { try await core.auth.submitSecondFactor(.totp("12"), for: prompt) }
        #expect(core.server.count("POST auth/second-factor/step-up") == 2, "a malformed code is not sent")
    }

    /// Server shape (routes/auth.ts `/login`, services/secondFactor/signIn.ts).
    private let challengeJSON = #"{"secondFactorRequired":true,"challenge":"chal-1","expiresAt":"2099-01-01T00:05:00.000Z","methods":["totp","passkey","backup_code"],"maskedEmail":"p***@example.invalid"}"#

    @Test func passwordLoginChallengeIsAnsweredAtVerify() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, challengeJSON))
        core.server.on("POST auth/second-factor/verify", .json(200, loginJSON))
        core.server.on("GET auth/me", .json(200, userJSON))
        core.server.on("GET servers", .json(200, serversJSON))
        let outcome = try await core.auth.signIn(email: "a@b.c", password: "pw")
        guard case .secondFactorRequired(let prompt) = outcome else { Issue.record("no prompt"); return }
        guard case .signInChallenge(let challenge) = prompt.stage else { Issue.record("expected a sign-in challenge"); return }
        #expect(challenge.token == "chal-1")
        #expect(challenge.maskedEmail == "p***@example.invalid")
        #expect(challenge.expiresAt == ISO8601.parse("2099-01-01T00:05:00.000Z"))
        #expect(prompt.methods == [.totp, .passkey, .backupCode])
        #expect(prompt.usableMethods == [.totp, .backupCode])
        #expect(prompt.refusedCall == "POST auth/login")
        #expect(prompt.trigger == "HTTP 2xx secondFactorRequired=true challenge=present keys=[challenge,expiresAt,maskedEmail,methods,secondFactorRequired] methods=[totp,passkey,backup_code]")
        #expect(!String(describing: prompt).contains("chal-1"), "the challenge is redacted")

        let done = try await core.auth.submitSecondFactor(.totp("654 321"), for: prompt)
        guard case .signedIn(let session) = done else { Issue.record("not signed in: \(done)"); return }
        #expect(session.servers.count == 2)
        let verify = try #require(core.server.requests("POST auth/second-factor/verify").first)
        #expect(verify.json == ["challenge": "chal-1", "code": "654321"])
        #expect(verify.header("Authorization") == nil)
        #expect(verify.header("X-Server-Id") == nil)
        #expect(core.server.count("POST auth/login") == 1, "the password is sent once")
    }

    @Test func backupCodeAnswersTheChallenge() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, challengeJSON))
        core.server.on("POST auth/second-factor/verify", .json(200, #"{"user":{"id":"u-1"},"accessToken":"access-1","refreshToken":"refresh-1","backupCodesRemaining":9}"#))
        core.server.on("GET auth/me", .json(200, userJSON))
        core.server.on("GET servers", .json(200, serversJSON))
        guard case .secondFactorRequired(let prompt) = try await core.auth.signIn(email: "a@b.c", password: "pw") else {
            Issue.record("no prompt"); return
        }
        let done = try await core.auth.submitSecondFactor(.backupCode(" abcd-efgh "), for: prompt)
        guard case .signedIn = done else { Issue.record("not signed in"); return }
        #expect(core.server.requests("POST auth/second-factor/verify").first?.json == ["challenge": "chal-1", "backupCode": "abcd-efgh"])
        #expect(LoginSecondFactorContract.path == "auth/second-factor/verify")
    }

    @Test func challengeRefusals() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, challengeJSON))
        core.server.on("POST auth/second-factor/verify", replies: [
            .json(400, #"{"error":"That code didn't work.","code":"second_factor_code_invalid"}"#),
            .json(400, #"{"error":"That backup code was already used.","code":"backup_code_used"}"#),
            .json(429, #"{"error":"Too many wrong codes.","code":"second_factor_locked","lockedUntil":"2026-11-24T10:15:00.000Z","methods":["totp"]}"#),
            .json(410, #"{"error":"This sign-in has expired. Sign in again.","code":"challenge_expired"}"#),
            .json(429, #"{"error":"Too many wrong codes for this sign-in.","code":"challenge_attempts_exhausted"}"#),
        ])
        guard case .secondFactorRequired(let prompt) = try await core.auth.signIn(email: "a@b.c", password: "pw") else {
            Issue.record("no prompt"); return
        }
        let wrong = try await core.auth.submitSecondFactor(.totp("000000"), for: prompt)
        #expect(wrong == .secondFactorRefused(.codeInvalid, prompt))
        let used = try await core.auth.submitSecondFactor(.backupCode("abcd-efgh"), for: prompt)
        #expect(used == .secondFactorRefused(.backupCodeUsed, prompt))
        let locked = try await core.auth.submitSecondFactor(.totp("111111"), for: prompt)
        #expect(locked == .secondFactorRefused(.locked(until: ISO8601.parse("2026-11-24T10:15:00.000Z")), prompt))
        let expired = try await core.auth.submitSecondFactor(.totp("222222"), for: prompt)
        #expect(expired == .secondFactorRefused(.challengeExpired, prompt))
        let exhausted = try await core.auth.submitSecondFactor(.totp("333333"), for: prompt)
        #expect(exhausted == .secondFactorRefused(.attemptsExhausted, prompt))
        #expect(!SecondFactorResult.codeInvalid.endsSignIn && !SecondFactorResult.locked(until: nil).endsSignIn)
        #expect(SecondFactorResult.challengeExpired.endsSignIn && SecondFactorResult.attemptsExhausted.endsSignIn)
        #expect(await core.session.current == nil)
    }

    @Test func challengeWithoutTokenIsAnError() async {
        let core = TestCore()
        core.server.on("POST auth/login", .json(200, #"{"secondFactorRequired":true,"methods":["totp"]}"#))
        await #expect(throws: AuthFlowError.missingTokens(keys: ["methods", "secondFactorRequired"])) {
            try await core.auth.signIn(email: "a@b.c", password: "pw")
        }
    }

    @Test func wrongCredentialsAreAnHTTPError() async throws {
        let core = TestCore()
        core.server.on("POST auth/login", .json(401, #"{"error":"Invalid email or password","code":"AUTH_INVALID_CREDENTIALS"}"#))
        do {
            _ = try await core.auth.signIn(email: "a@b.c", password: "pw")
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error.status == 401)
            #expect(error.serverCode == "AUTH_INVALID_CREDENTIALS")
        }
        #expect(core.server.count("POST auth/refresh") == 0, "an unauthenticated 401 never refreshes")
        await #expect(throws: AuthFlowError.validation("Email and password are required.")) {
            try await core.auth.signIn(email: " ", password: "pw")
        }
    }

    @Test func browserLoginRunsPKCE() async throws {
        let core = TestCore()
        core.server.on("POST auth/app-login/start", .json(201, #"{"requestId":"req-1","loginUrl":"https://app.raft.build/login/app?request=req-1","expiresAt":"2026-11-24T10:05:00Z"}"#))
        core.server.on("POST auth/app-login/complete", .json(200, loginJSON))
        core.server.on("GET auth/me", .json(200, userJSON))
        core.server.on("GET servers", .json(200, "[]"))
        let attempt = try await core.auth.startBrowserLogin()
        let start = try #require(core.server.requests("POST auth/app-login/start").first?.json)
        #expect(start["returnUri"] == "raft-debug://login/callback")
        #expect(start["codeChallengeMethod"] == "S256")
        #expect(start["codeChallenge"]?.stringValue == PKCEPair.challenge(for: attempt.pkce.verifier))
        #expect(attempt.loginURL.host() == "app.raft.build")

        await #expect(throws: AuthFlowError.callbackRequestMismatch) {
            try await core.auth.completeBrowserLogin(attempt, callbackURL: URL(string: "raft-debug://login/callback?requestId=other&code=c")!)
        }
        await #expect(throws: AuthFlowError.browserError("access_denied")) {
            try await core.auth.completeBrowserLogin(attempt, callbackURL: URL(string: "raft-debug://login/callback?requestId=req-1&error=access_denied")!)
        }
        let outcome = try await core.auth.completeBrowserLogin(attempt, callbackURL: URL(string: "raft-debug://login/callback?requestId=req-1&code=code-1")!)
        guard case .signedIn(let session) = outcome else { Issue.record("not signed in"); return }
        #expect(session.selectedServerId == nil)
        let complete = try #require(core.server.requests("POST auth/app-login/complete").first?.json)
        #expect(complete == ["code": "code-1", "codeVerifier": .string(attempt.pkce.verifier), "returnUri": "raft-debug://login/callback"])
    }

    @Test func browserLoginRejectsNonHTTPSPages() async {
        let core = TestCore()
        core.server.on("POST auth/app-login/start", .json(201, #"{"requestId":"r","loginUrl":"http://evil.example/login"}"#))
        await #expect(throws: AuthFlowError.browserLoginURLRejected) { try await core.auth.startBrowserLogin() }
        #expect(AuthService.isAllowedLoginURL(URL(string: "http://localhost:3000/login/app")!))
    }

    @Test func signOutRevokesAndClears() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST auth/logout", .json(200, "{}"))
        await core.auth.signOut()
        #expect(core.server.requests("POST auth/logout").first?.json == ["refreshToken": "refresh-1"])
        #expect(await core.session.current == nil)
        #expect(SessionStore(secure: core.secure).load(.production) == nil)
    }

    @Test func selectingAServerPersistsAndSwitchesHeader() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, "[]"))
        _ = await core.session.selectServer("srv-2")
        _ = await core.session.selectServer("missing")
        _ = try await core.api.channels()
        #expect(core.server.requests.first?.header("X-Server-Id") == "srv-2")
        #expect(SessionStore(secure: core.secure).load(.production)?.selectedServerId == "srv-2")
        #expect(StoredSession.resolveSelection(current: "gone", servers: [AuthServer(id: "a", name: "A")]) == "a")
    }

    @Test func installationIdIsStable() {
        let store = SessionStore(secure: InMemorySecureStore())
        let first = store.installationId()
        #expect(InstallationId.isValid(first))
        #expect(store.installationId() == first)
    }

    @Test func descriptionsRedactSecrets() {
        let session = sampleSession(access: "secret-access", refresh: "secret-refresh")
        #expect(!String(describing: session).contains("secret"))
        #expect(!String(describing: session.tokens).contains("secret"))
        let challenge = SignInChallenge(token: "chal-secret", expiresAt: nil, maskedEmail: nil, methodNames: [])
        let prompt = SecondFactorPrompt(stage: .signInChallenge(challenge), methods: [], serverMessage: nil, refusedCall: "x")
        #expect(!String(describing: prompt).contains("secret"))
        #expect(!String(reflecting: challenge).contains("secret"))
    }
}
