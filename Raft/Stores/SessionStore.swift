import Foundation
import Observation

/// Something that runs the browser sign-in page and returns the callback URL.
@MainActor
protocol BrowserAuthenticating: AnyObject {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

extension WebAuthenticator: BrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await authenticate(url: url, callbackScheme: callbackScheme, ephemeral: false)
    }
}

/// Who is signed in, and the sign-in flows (password, browser, two-step). Mirrors the core's
/// `SessionManager` (Keychain-backed) for the UI. Never holds the password after a sign-in call.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        /// Reading the Keychain at launch.
        case restoring
        case signedOut
        /// The password was right; the account asks for a second factor.
        case secondFactor(SecondFactorPrompt)
        case signedIn
    }

    private(set) var phase: Phase = .restoring
    private(set) var session: StoredSession?
    private(set) var busy = false
    /// The last failure, for the screen.
    var errorMessage: String?
    /// Something the person should know that is not an error (session expired, signed out).
    var notice: String?
    /// Set by an interactive sign-in (not a restore): the app offers the server choice once.
    private(set) var signedInInteractively = false

    @ObservationIgnored let core: CoreServices
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init(core: CoreServices) {
        self.core = core
    }

    var user: AuthUser? { session?.user }

    // MARK: Lifecycle

    func start() async {
        apply(await core.session.current)
        watch()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func watch() {
        watchTask?.cancel()
        let manager = core.session
        watchTask = Task { [weak self] in
            for await event in await manager.events() {
                guard let self else { return }
                switch event {
                case .signedIn(let value), .updated(let value):
                    self.apply(value)
                case .signedOut:
                    self.apply(nil)
                case .expired:
                    self.apply(nil)
                    self.notice = "Your session expired. Sign in again."
                }
            }
        }
    }

    /// Takes the core's session as the current one.
    func apply(_ value: StoredSession?) {
        session = value
        if value != nil {
            phase = .signedIn
        } else if case .secondFactor = phase {
            // Keep the prompt: no session exists until the second factor is answered.
        } else {
            phase = .signedOut
            signedInInteractively = false
        }
    }

    // MARK: Sign-in

    func signIn(email: String, password: String) async {
        await perform {
            let outcome = try await self.core.auth.signIn(email: email, password: password)
            self.handle(outcome)
        }
    }

    func signInWithBrowser(using authenticator: BrowserAuthenticating) async {
        await perform {
            let attempt = try await self.core.auth.startBrowserLogin()
            let callback = try await authenticator.authenticate(url: attempt.loginURL, callbackScheme: attempt.callbackScheme)
            let outcome = try await self.core.auth.completeBrowserLogin(attempt, callbackURL: callback)
            self.handle(outcome)
        }
    }

    func submitSecondFactor(_ answer: SecondFactorAnswer) async {
        guard case .secondFactor(let prompt) = phase else { return }
        await perform {
            let outcome = try await self.core.auth.submitSecondFactor(answer, for: prompt)
            self.handle(outcome)
        }
    }

    func cancelSecondFactor() {
        guard case .secondFactor = phase else { return }
        phase = .signedOut
        errorMessage = nil
    }

    private func handle(_ outcome: SignInOutcome) {
        switch outcome {
        case .signedIn(let value):
            errorMessage = nil
            notice = nil
            signedInInteractively = true
            session = value
            phase = .signedIn
        case .secondFactorRequired(let prompt):
            phase = .secondFactor(prompt)
            errorMessage = prompt.passkeyOnly
                ? "This account only has a passkey. Use the browser sign-in."
                : nil
        case .secondFactorRefused(let result, let prompt):
            errorMessage = result.displayMessage
            phase = result.endsSignIn ? .signedOut : .secondFactor(prompt)
        }
    }

    // MARK: Account

    func reloadAccount() async {
        do {
            if let value = try await core.auth.reloadAccount() { apply(value) }
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }

    /// The server choice was made (see `signedInInteractively`).
    func acknowledgeServerChoice() {
        signedInInteractively = false
    }

    func signOut() async {
        busy = true
        await core.auth.signOut()
        busy = false
        apply(nil)
        notice = "Signed out."
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await work()
        } catch AuthFlowError.cancelled {
            // The person closed the browser sheet.
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }
}

/// The servers (workspaces) of the signed-in account and the selected one. Selection is kept in
/// the stored session, so it survives relaunch and every request carries it as `X-Server-Id`.
@MainActor
@Observable
final class ServerStore {
    private(set) var isReloading = false
    var errorMessage: String?

    @ObservationIgnored let sessionStore: SessionStore

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    var servers: [AuthServer] { sessionStore.session?.servers ?? [] }
    var selectedServerId: String? { sessionStore.session?.selectedServerId }
    var selectedServer: AuthServer? { sessionStore.session?.selectedServer }

    /// Show the server picker: no server selected, or a fresh sign-in into an account with
    /// several servers (once).
    var needsChoice: Bool {
        guard sessionStore.phase == .signedIn else { return false }
        if selectedServerId == nil { return true }
        return sessionStore.signedInInteractively && servers.count > 1
    }

    func select(_ id: String) async {
        let updated = await sessionStore.core.session.selectServer(id)
        if let updated { sessionStore.apply(updated) }
        sessionStore.acknowledgeServerChoice()
    }

    /// Re-reads profile and servers (pull to refresh, membership changes).
    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        do {
            if let value = try await sessionStore.core.auth.reloadAccount() { sessionStore.apply(value) }
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }
}
