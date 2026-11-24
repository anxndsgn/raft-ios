import SwiftUI

/// Launch → sign-in → main, cross-faded (§3, §7).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private enum Stage: Hashable {
        case launch
        case auth
        case main
    }

    private var stage: Stage {
        switch model.session.phase {
        case .restoring: return .launch
        case .signedIn:
            if model.servers.needsChoice { return .auth }
            return model.workspace == nil ? .launch : .main
        case .signedOut, .secondFactor: return .auth
        }
    }

    var body: some View {
        ZStack {
            switch stage {
            case .launch:
                LaunchView().transition(.opacity)
            case .auth:
                AuthFlowView().transition(.opacity)
            case .main:
                if let workspace = model.workspace {
                    MainTabView()
                        .environment(workspace)
                        .id(workspace.serverId)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stage)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastPill(text: toast)
                    .padding(.bottom, 110)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .task { await model.start() }
        .onChange(of: model.session.phase) { model.syncWorkspace() }
        .onChange(of: model.servers.selectedServerId) { model.syncWorkspace() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.foreground() } }
        }
    }
}

/// The launch screen's look (yellow, mark) while the Keychain is read.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Image("LaunchMark")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 102)
                .accessibilityLabel(Text(verbatim: "Raft"))
        }
    }
}

/// Home / Activity / Settings (§2.11).
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace

    private var activityUnread: Bool {
        guard workspace.channelList.phase == .loaded else { return false }
        if workspace.activity.phase == .loaded { return workspace.activity.unreadRowCount > 0 }
        return workspace.channelList.attentionCount > 0
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab(value: AppTab.home) {
                NavigationStack(path: $model.homePath) {
                    HomeView().routeDestinations()
                }
            } label: {
                Label(L10n.t("tab_home", "Home"), systemImage: model.tab == .home ? "house.fill" : "house")
            }
            .accessibilityIdentifier("tab-home")
            Tab(value: AppTab.activity) {
                NavigationStack(path: $model.activityPath) {
                    ActivityView().routeDestinations()
                }
            } label: {
                Label(L10n.t("tab_activity", "Activity"), systemImage: "waveform.path.ecg")
            }
            .badge(activityUnread ? Text(verbatim: "") : nil)
            .accessibilityValue(activityUnread ? Text(L10n.t("tab_activity_unread_dot", "Unread activity")) : Text(verbatim: ""))
            .accessibilityIdentifier("tab-activity")
            Tab(value: AppTab.settings) {
                NavigationStack(path: $model.settingsPath) {
                    SettingsView().routeDestinations()
                }
            } label: {
                Label(L10n.t("tab_settings", "Settings"), systemImage: model.tab == .settings ? "gearshape.fill" : "gearshape")
            }
            .accessibilityIdentifier("tab-settings")
        }
        .tint(.raftTextPrimary)
    }
}

extension View {
    /// The pushes every tab's stack can show.
    func routeDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteView(route: route)
        }
    }
}

struct RouteView: View {
    let route: AppRoute
    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch route {
        case .conversation(let ref):
            ChatView(store: workspace.conversation(for: ref), ref: ref)
                .toolbar(.hidden, for: .tabBar)
        case .thread(let ref):
            ThreadView(store: workspace.thread(for: ref))
                .toolbar(.hidden, for: .tabBar)
        case .servers:
            ServerPickerView(showsBack: true)
        case .saved:
            SavedView()
        }
    }
}
