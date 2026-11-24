import Foundation
import Observation

/// State and actions of the core debug screen. Never records secrets: no password, token,
/// code or TOTP secret reaches `log`, `statusLine` or the console.
@MainActor
@Observable
final class DebugCoreModel {
    var environmentKind: RaftEnvironment.Kind
    var email = ""
    var password = ""
    var busy = false
    var statusLine: String?
    var session: StoredSession?
    var prompt: SecondFactorPrompt?
    var method: SecondFactorMethod = .totp
    var code = ""
    /// DEBUG helper input (base32 authenticator secret); unused in Release.
    var totpSecret = ""
    var socketStatus: RealtimeStatus = .idle
    var eventCount = 0
    var lastEventName: String?
    var versionSummary: String?
    private(set) var log: [String] = []

    @ObservationIgnored private var core: CoreServices
    @ObservationIgnored private let environmentStore: EnvironmentStore
    @ObservationIgnored private let webAuthenticator = WebAuthenticator()
    @ObservationIgnored private var realtime: RealtimeClient?
    @ObservationIgnored private var realtimeTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var sessionTask: Task<Void, Never>?

    init(environmentStore: EnvironmentStore = EnvironmentStore()) {
        self.environmentStore = environmentStore
        let environment = environmentStore.current
        environmentKind = environment.kind
        core = CoreServices.make(environment: environment)
    }

    var environment: RaftEnvironment { core.environment }

    // MARK: Lifecycle

    func start() async {
        session = await core.session.current
        watchSession()
        if session != nil { await startRealtime() }
    }

    func switchEnvironment(to kind: RaftEnvironment.Kind) async {
        guard kind != core.environment.kind else { return }
        await stopRealtime()
        sessionTask?.cancel()
        environmentStore.set(kind)
        environmentKind = kind
        core = CoreServices.make(environment: .of(kind))
        prompt = nil
        code = ""
        statusLine = nil
        versionSummary = nil
        record("Environment → \(kind.rawValue) (\(core.environment.apiBaseURL.host() ?? ""))")
        await start()
    }

    private func watchSession() {
        sessionTask?.cancel()
        let session = core.session
        sessionTask = Task { [weak self] in
            for await event in await session.events() {
                guard let self else { return }
                switch event {
                case .signedIn(let value), .updated(let value):
                    self.session = value
                case .signedOut:
                    self.session = nil
                case .expired:
                    self.session = nil
                    self.statusLine = "Session expired. Sign in again."
                    self.record("Session expired")
                    await self.stopRealtime()
                }
            }
        }
    }

    // MARK: Sign-in

    func signIn() async {
        await run("Sign in") {
            let outcome = try await self.core.auth.signIn(email: self.email, password: self.password)
            await self.handle(outcome)
        }
    }

    func signInWithBrowser() async {
        await run("Browser sign-in") {
            let attempt = try await self.core.auth.startBrowserLogin()
            self.record("Browser sign-in started (\(attempt.loginURL.host() ?? "?"))")
            let callback = try await self.webAuthenticator.authenticate(url: attempt.loginURL, callbackScheme: attempt.callbackScheme)
            let outcome = try await self.core.auth.completeBrowserLogin(attempt, callbackURL: callback)
            await self.handle(outcome)
        }
    }

    func submitSecondFactor() async {
        guard let prompt else { return }
        let answer: SecondFactorAnswer = method == .backupCode ? .backupCode(code) : .totp(code)
        await run("Verify \(method.rawValue)") {
            let outcome = try await self.core.auth.submitSecondFactor(answer, for: prompt)
            await self.handle(outcome)
        }
    }

    func cancelSecondFactor() {
        prompt = nil
        code = ""
        statusLine = nil
    }

    #if DEBUG
    /// Fills the code field from the DEBUG TOTP secret. The secret and the code are never logged.
    func fillCodeFromSecret() {
        guard let generated = DebugTOTP.code(secretBase32: totpSecret) else {
            statusLine = "That secret is not valid base32."
            return
        }
        method = .totp
        code = generated
        statusLine = "Code filled (valid ~\(DebugTOTP.secondsRemaining())s)."
    }
    #endif

    private func handle(_ outcome: SignInOutcome) async {
        switch outcome {
        case .signedIn(let value):
            session = value
            prompt = nil
            code = ""
            password = ""
            statusLine = "Signed in as \(value.user.visibleName)\(value.user.needsProfileSetup ? " (profile setup needed)" : "")."
            record("Signed in: \(value.servers.count) servers")
            await startRealtime()
        case .secondFactorRequired(let value):
            prompt = value
            method = value.usableMethods.first ?? .totp
            code = ""
            let methods = value.methods.map(\.rawValue).joined(separator: ",")
            statusLine = value.passkeyOnly
                ? "This account only has a passkey. Passkeys aren't supported here yet; use another method (authenticator or backup code) or sign in with the browser."
                : "Two-step verification required."
            record("Step-up required: \(value.refusedCall) → second_factor_step_up_required; stage=\(Self.stageName(value)); methods=[\(methods)]")
        case .secondFactorRefused(let result, let value):
            code = ""
            statusLine = result.displayMessage
            record("Step-up refused: \(Self.resultName(result))")
            if case .sessionFamilyRequired = result { prompt = nil } else { prompt = value }
        }
    }

    // MARK: Account

    func selectServer(_ id: String) async {
        guard id != session?.selectedServerId else { return }
        session = await core.session.selectServer(id)
        record("Selected server \(session?.selectedServer?.name ?? id)")
        await startRealtime()
    }

    func reloadAccount() async {
        await run("Reload") {
            _ = try await self.core.auth.reloadAccount()
            self.statusLine = "Account reloaded."
        }
    }

    func signOut() async {
        await stopRealtime()
        await core.auth.signOut()
        session = nil
        prompt = nil
        statusLine = "Signed out."
        record("Signed out")
    }

    func fetchVersion() async {
        await run("GET version") {
            let value = try await self.core.api.version()
            let keys = value.objectValue.map { $0.keys.sorted().joined(separator: ",") } ?? "?"
            let version = value["version"]?.stringValue ?? value["commit"]?.stringValue
            self.versionSummary = "OK \(version.map { "version \($0) · " } ?? "")keys: \(keys)"
        }
    }

    // MARK: Realtime

    func startRealtime() async {
        await stopRealtime()
        guard let serverId = session?.selectedServerId else {
            socketStatus = .stopped(reason: "no_server")
            return
        }
        let client = core.makeRealtime(serverId: serverId)
        realtime = client
        eventCount = 0
        lastEventName = nil
        let statuses = await client.statuses()
        let events = await client.events()
        realtimeTasks = [
            Task { [weak self] in
                for await status in statuses { self?.socketStatus = status }
            },
            Task { [weak self] in
                for await event in events {
                    self?.eventCount += 1
                    self?.lastEventName = event.name
                }
            },
        ]
        await client.start()
    }

    func stopRealtime() async {
        for task in realtimeTasks { task.cancel() }
        realtimeTasks = []
        if let realtime { await realtime.stop() }
        realtime = nil
        socketStatus = .idle
    }

    func reconnectRealtime() async {
        if let realtime { await realtime.reconnectNow() } else { await startRealtime() }
    }

    // MARK: Helpers

    private func run(_ label: String, _ work: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch {
            let text = Self.describe(error)
            statusLine = text
            record("\(label) failed: \(text)")
        }
    }

    private func record(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(stamp) \(line)", at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? APIError {
            if case .http(_, let body, _) = error, let keys = body?.keys, !keys.isEmpty {
                return "\(error.localizedDescription) [keys: \(keys.joined(separator: ","))]"
            }
            return error.localizedDescription
        }
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: type(of: error))
    }

    private static func stageName(_ prompt: SecondFactorPrompt) -> String {
        switch prompt.stage {
        case .session: "session"
        case .credentials: "credentials"
        }
    }

    private static func resultName(_ result: SecondFactorResult) -> String {
        switch result {
        case .verified: "verified"
        case .codeInvalid: "second_factor_code_invalid"
        case .backupCodeUsed: "backup_code_used"
        case .locked: "second_factor_locked"
        case .notEnabled: "second_factor_not_enabled"
        case .sessionFamilyRequired: "session_family_required"
        case .failed(let status, let code, _): "HTTP \(status) \(code ?? "")"
        }
    }
}
