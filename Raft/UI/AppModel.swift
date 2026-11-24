import SwiftUI
import Observation

/// Pushes inside the sign-in flow.
enum AuthRoute: Hashable {
    case totp
    case backupCode
    case servers
}

/// The app: core services, the session, the selected server's workspace and the navigation state
/// of each tab.
@MainActor
@Observable
final class AppModel {
    let core: CoreServices
    let session: SessionStore
    let servers: ServerStore
    let preferences: AppPreferences
    private(set) var workspace: Workspace?

    var tab: AppTab = .home
    var homePath: [AppRoute] = []
    var activityPath: [AppRoute] = []
    var settingsPath: [AppRoute] = []
    var authPath: [AuthRoute] = []
    /// The person picked "Switch server" from Home: the picker shows over the main UI.
    var showsServerPicker = false
    /// A short confirmation pill ("Copied").
    var toast: String?

    /// Built once per signed-in person and server; keyed so a change rebuilds it.
    @ObservationIgnored private var workspaceKey: String?
    @ObservationIgnored let webAuthenticator = WebAuthenticator()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Preview gallery: no network, no socket.
    @ObservationIgnored let isPreview: Bool

    init(core: CoreServices, preferences: AppPreferences = AppPreferences(), isPreview: Bool = false) {
        self.core = core
        self.preferences = preferences
        self.isPreview = isPreview
        session = SessionStore(core: core)
        servers = ServerStore(sessionStore: session)
    }

    static func live() -> AppModel {
        AppModel(core: CoreServices.make(environment: EnvironmentStore().current))
    }

    var environment: RaftEnvironment { core.environment }

    // MARK: Lifecycle

    func start() async {
        guard !isPreview else { return }
        await session.start()
        syncWorkspace()
    }

    /// Builds, keeps or closes the workspace to match the session's person and server.
    func syncWorkspace() {
        guard !isPreview else { return }
        let user = session.phase == .signedIn ? session.user : nil
        let serverId = servers.selectedServerId
        let key = user.flatMap { user in serverId.map { "\(user.id)|\($0)" } }
        guard key != workspaceKey else { return }
        workspaceKey = key
        let old = workspace
        if let old { Task { await old.stop() } }
        homePath = []
        activityPath = []
        guard let user, let serverId else {
            workspace = nil
            return
        }
        let next = Workspace(
            serverId: serverId,
            currentUserId: user.id,
            api: core.api,
            preferences: preferences,
            realtime: core.makeRealtime(serverId: serverId)
        )
        next.onMembershipChange = { [weak self] in
            Task { await self?.servers.reload() }
        }
        workspace = next
        Task {
            async let started: Void = next.start()
            async let directory: Void = next.directory.load()
            async let extras: Void = next.homeExtras.load()
            _ = await (started, directory, extras)
        }
    }

    /// Preview gallery: shows a prepared workspace.
    func installPreview(workspace: Workspace) {
        self.workspace = workspace
    }

    func foreground() async {
        guard !isPreview, let workspace else { return }
        await workspace.resumeForeground()
        await workspace.directory.load()
    }

    // MARK: Actions

    /// Pushes onto the current tab's stack.
    func push(_ route: AppRoute) {
        switch tab {
        case .home: homePath.append(route)
        case .activity: activityPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    func selectServer(_ id: String) async {
        guard id != servers.selectedServerId else {
            servers.sessionStore.acknowledgeServerChoice()
            return
        }
        await servers.select(id)
        syncWorkspace()
    }

    func signOut() async {
        await workspace?.stop()
        workspace = nil
        workspaceKey = nil
        homePath = []
        activityPath = []
        settingsPath = []
        authPath = []
        tab = .home
        await session.signOut()
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
    }

    // MARK: Web pages

    func webURL(_ path: String) -> URL {
        core.environment.webURL.appending(path: path)
    }

    static let termsURL = URL(string: "https://raft.build/terms")!
    static let privacyURL = URL(string: "https://raft.build/privacy")!
}
