import Foundation
import Testing
@testable import Raft

struct RequestHeadersTests {
    @Test func headersCarryClientIdentityTraceAndAuth() throws {
        let trace = TraceIds(traceId: String(repeating: "a", count: 32), spanId: String(repeating: "b", count: 16))
        let headers = RequestHeaders.build(appInfo: testAppInfo, accessToken: "tok", serverId: "srv", trace: trace)
        #expect(headers["Authorization"] == "Bearer tok")
        #expect(headers["X-Server-Id"] == "srv")
        #expect(headers["X-Raft-Client-Platform"] == "ios")
        #expect(headers["X-Raft-Client-Version"] == "1.2.3")
        #expect(headers["User-Agent"] == "Raft/1.2.3+45 (iOS 26.0; debug) iPhone")
        #expect(headers["traceparent"] == "00-\(trace.traceId)-\(trace.spanId)-01")
        #expect(headers["x-request-id"] == "mobile-\(trace.traceId)")
    }

    @Test func noAuthOrServerWhenAbsentAndExtraWins() {
        let headers = RequestHeaders.build(appInfo: testAppInfo, accessToken: nil, serverId: "", extra: ["user-agent": "custom"])
        #expect(headers["Authorization"] == nil)
        #expect(headers["X-Server-Id"] == nil)
        #expect(headers["User-Agent"] == nil)
        #expect(headers["user-agent"] == "custom")
    }

    @Test func randomTraceIdsHaveW3CShape() {
        let trace = TraceIds.random()
        #expect(trace.traceId.count == 32 && trace.traceId.allSatisfy(\.isHexDigit))
        #expect(trace.spanId.count == 16 && trace.spanId.allSatisfy(\.isHexDigit))
        #expect(InstallationId.isValid(InstallationId.generate()))
        #expect(RefreshAttemptId.isValid(RefreshAttemptId.generate()))
        #expect(!RefreshAttemptId.isValid("arf_xyz"))
    }

    @Test func environmentsBuildURLs() {
        #expect(RaftEnvironment.production.apiURL(path: "channels/dm").absoluteString == "https://api.raft.build/api/channels/dm")
        #expect(RaftEnvironment.staging.apiURL(path: "/servers").absoluteString == "https://api-aws-staging.botiverse.dev/api/servers")
        let url = RaftEnvironment.production.apiURL(path: "x", query: [URLQueryItem(name: "q", value: "a+b c")])
        #expect(url.absoluteString == "https://api.raft.build/api/x?q=a%2Bb%20c")
    }

    @Test func environmentSwitchPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "raft-test-\(UUID().uuidString)"))
        let store = EnvironmentStore(defaults: defaults)
        #expect(store.current == .production)
        store.set(.staging)
        #expect(EnvironmentStore(defaults: defaults).current == .staging)
    }
}

struct HTTPClientTests {
    @Test func sendsSessionTokenAndSelectedServer() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, #"[{"id":"c1","name":"general","type":"channel","joined":true,"maxReadSeq":"12"}]"#))
        let channels = try await core.api.channels()
        #expect(channels.map(\.id) == ["c1"])
        #expect(channels.first?.maxReadSeq == 12)
        let request = try #require(core.server.requests.first)
        #expect(request.header("Authorization") == "Bearer access-1")
        #expect(request.header("X-Server-Id") == "srv-1")
        #expect(request.header("X-Raft-Client-Platform") == "ios")
    }

    @Test func overloadedReadWarehouseRetriesOnceAfterRetryAfter() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", replies: [
            .json(503, #"{"error":"busy","code":"rw_overloaded"}"#, headers: ["Retry-After": "3"]),
            .json(200, "[]"),
        ])
        _ = try await core.api.channels()
        #expect(core.server.count("GET channels") == 2)
        #expect(core.sleeps.sleeps == [3])
    }

    @Test func overloadedDefaultsToTwoSecondsAndCapsAtTen() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", replies: [.json(503, #"{"code":"rw_overloaded"}"#), .json(200, "[]")])
        core.server.on("GET channels/dm", replies: [.json(503, #"{"code":"rw_overloaded"}"#, headers: ["Retry-After": "600"]), .json(200, "[]")])
        _ = try await core.api.channels()
        _ = try await core.api.directMessages()
        #expect(core.sleeps.sleeps == [2, 10])
    }

    @Test func secondOverloadAndOther503AreErrors() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(503, #"{"code":"rw_overloaded"}"#))
        core.server.on("GET channels/dm", .json(503, #"{"code":"maintenance"}"#))
        await #expect(throws: APIError.self) { try await core.api.channels() }
        #expect(core.server.count("GET channels") == 2, "one retry only")
        do {
            _ = try await core.api.directMessages()
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error.status == 503)
            #expect(error.serverCode == "maintenance")
        }
        #expect(core.server.count("GET channels/dm") == 1)
    }

    @Test func unauthorizedRefreshesRotatesAndRetries() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels") { request, _ in
            request.header("Authorization") == "Bearer access-2" ? .json(200, "[]") : .json(401, #"{"error":"expired"}"#)
        }
        core.server.on("POST auth/refresh", .json(200, #"{"accessToken":"access-2","refreshToken":"refresh-2"}"#))
        _ = try await core.api.channels()
        let refresh = try #require(core.server.requests("POST auth/refresh").first)
        #expect(refresh.json == ["refreshToken": "refresh-1"])
        #expect(RefreshAttemptId.isValid(refresh.header("X-Slock-Auth-Refresh-Attempt-Id") ?? ""))
        #expect(InstallationId.isValid(refresh.header("X-Slock-Auth-Installation-Id") ?? ""))
        #expect(refresh.header("Authorization") == nil)
        let stored = await core.session.current
        #expect(stored?.tokens == TokenPair(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(SessionVault(secure: core.secure).load(.production)?.tokens.refreshToken == "refresh-2", "rotation is persisted")
    }

    @Test func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let core = TestCore(session: sampleSession())
        core.server.latency = 0.02
        core.server.on("GET channels") { request, _ in
            request.header("Authorization") == "Bearer access-2" ? .json(200, "[]") : .json(401, "{}")
        }
        core.server.on("POST auth/refresh", .json(200, #"{"accessToken":"access-2","refreshToken":"refresh-2"}"#))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await core.api.channels() } }
            try await group.waitForAll()
        }
        #expect(core.server.count("POST auth/refresh") == 1)
        #expect(await core.session.refreshCount == 1)
    }

    @Test func ambiguousRefreshReplaysTheSameAttempt() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels") { request, _ in
            request.header("Authorization") == "Bearer access-2" ? .json(200, "[]") : .json(401, "{}")
        }
        core.server.on("POST auth/refresh", replies: [
            .transportFailure(),
            .json(200, #"{"accessToken":"access-2","refreshToken":"refresh-2"}"#),
        ])
        _ = try await core.api.channels()
        let attempts = core.server.requests("POST auth/refresh").map { $0.header("X-Slock-Auth-Refresh-Attempt-Id") }
        #expect(attempts.count == 2)
        #expect(attempts[0] != nil && attempts[0] == attempts[1])
    }

    @Test func rejectedRefreshExpiresTheSession() async throws {
        let core = TestCore(session: sampleSession())
        let events = await core.session.events()
        core.server.on("GET channels", .json(401, "{}"))
        core.server.on("POST auth/refresh", .json(401, #"{"error":"bad","code":"refresh_rotation_superseded"}"#))
        await #expect(throws: APIError.sessionExpired) { try await core.api.channels() }
        #expect(await core.session.current == nil)
        #expect(SessionVault(secure: core.secure).load(.production) == nil)
        #expect(await collect(events) { $0.contains(.expired) }.contains(.expired))
    }

    @Test func retriedUnauthorizedExpiresTheSession() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(401, "{}"))
        core.server.on("POST auth/refresh", .json(200, #"{"accessToken":"access-2","refreshToken":"refresh-2"}"#))
        await #expect(throws: APIError.sessionExpired) { try await core.api.channels() }
        #expect(core.server.count("GET channels") == 2, "retried exactly once")
        #expect(await core.session.current == nil)
    }

    @Test func refreshServerErrorKeepsTheSession() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(401, "{}"))
        core.server.on("POST auth/refresh", .json(502, "{}"))
        do {
            _ = try await core.api.channels()
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error.status == 502)
        }
        #expect(await core.session.current != nil)
    }

    @Test func noSessionMeansNotSignedIn() async {
        let core = TestCore()
        await #expect(throws: APIError.notSignedIn) { try await core.api.channels() }
        #expect(core.server.requests.isEmpty)
    }

    @Test func stepUpRefusalBecomesAChallenge() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(403, #"{"error":"Verify it's you","code":"second_factor_step_up_required","methods":["totp","backup_code"]}"#))
        do {
            _ = try await core.api.channels()
            Issue.record("expected a challenge")
        } catch APIError.secondFactorRequired(let challenge) {
            #expect(challenge.usableMethods == [.totp, .backupCode])
            #expect(challenge.path == "channels")
            #expect(challenge.serverMessage == "Verify it's you")
        }
    }

    @Test func errorBodiesAreTolerant() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(422, #"{"error":"Nope","code":42,"extra":{"a":1}}"#, headers: ["X-Trace-Id": "trace-9"]))
        do {
            _ = try await core.api.channels()
            Issue.record("expected an error")
        } catch let error as APIError {
            guard case .http(let status, let body, let traceId) = error else { Issue.record("not http"); return }
            #expect(status == 422)
            #expect(body?.code == nil, "a non-string code is dropped, not fatal")
            #expect(body?.displayMessage == "Nope")
            #expect(body?.keys == ["code", "error", "extra"])
            #expect(traceId == "trace-9")
        }
    }
}
