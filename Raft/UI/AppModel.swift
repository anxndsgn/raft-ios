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
    /// Set the moment sign-out is confirmed: the root shows the sign-in screen at once, before
    /// anything the main screens show (tab, paths, user, server) is torn down underneath.
    private(set) var signingOut = false

    /// Built once per signed-in person and server; keyed so a change rebuilds it.
    @ObservationIgnored private var workspaceKey: String?
    @ObservationIgnored let webAuthenticator = WebAuthenticator()
    @ObservationIgnored private let network = NetworkMonitor()
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
        KeychainStore().clearIfFreshInstall()
        return AppModel(core: CoreServices.make(environment: EnvironmentStore().current))
    }

    var environment: RaftEnvironment { core.environment }

    // MARK: Lifecycle

    func start() async {
        guard !isPreview else { return }
        network.onRestore = { [weak self] in
            Task { await self?.foreground() }
        }
        network.start()
        #if DEBUG
        scheduleOutageFromEnvironment()
        #endif
        await session.start()
        syncWorkspace()
    }

    #if DEBUG
    /// Developer menu: no network for `seconds`, then the network-restored path.
    func simulateOutage(seconds: Double) {
        SimulatedOutage.begin(seconds: seconds)
        Task {
            await workspace?.dropConnection()
            try? await Task.sleep(for: .seconds(seconds))
            network.update(satisfied: false)
            network.update(satisfied: true)
        }
    }

    /// `RAFT_SIMULATE_OUTAGE=<unix time>,<seconds>`: the outage starts at that time with no tap,
    /// so a recording can stay on the conversation.
    private func scheduleOutageFromEnvironment() {
        guard let raw = ProcessInfo.processInfo.environment["RAFT_SIMULATE_OUTAGE"] else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return }
        let start = Date(timeIntervalSince1970: parts[0])
        let seconds = parts[1]
        Task { [weak self] in
            let wait = start.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self?.simulateOutage(seconds: seconds)
        }
    }
    #endif

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
            // The first push of the session then shows messages from its first frame.
            await next.prefetchConversations()
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

    /// Back to the current tab's root (after leaving a channel).
    func popToRoot() {
        switch tab {
        case .home: homePath.removeAll()
        case .activity: activityPath.removeAll()
        case .settings: settingsPath.removeAll()
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
        // Root first, with no cross-fade: a fading Home would show its state being cleared.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { signingOut = true }
        defer { signingOut = false }
        // Let the swap reach the screen before the main screens' state changes.
        await Task.yield()
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

    func showToast(_ text: String, duration: Duration = .seconds(2)) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
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
