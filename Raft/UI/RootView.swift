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
        if model.signingOut { return .auth }
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
                    MainStage(workspace: workspace)
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

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
                tabLabel(L10n.t("tab_home", "Home"), model.tab == .home ? "house.fill" : "house")
            }
            .accessibilityIdentifier("tab-home")
            Tab(value: AppTab.activity) {
                NavigationStack(path: $model.activityPath) {
                    ActivityView().routeDestinations()
                }
            } label: {
                if activityUnread {
                    Label {
                        Text(verbatim: L10n.t("tab_activity", "Activity"))
                    } icon: {
                        Image(uiImage: ActivityTabImage.image(selected: model.tab == .activity, dark: scheme == .dark, scale: displayScale))
                            .renderingMode(.original)
                    }
                } else {
                    tabLabel(L10n.t("tab_activity", "Activity"), "waveform.path.ecg")
                }
            }
            .accessibilityValue(activityUnread ? Text(L10n.t("tab_activity_unread_dot", "Unread activity")) : Text(verbatim: ""))
            .accessibilityIdentifier("tab-activity")
            Tab(value: AppTab.settings) {
                NavigationStack(path: $model.settingsPath) {
                    SettingsView().routeDestinations()
                }
            } label: {
                tabLabel(L10n.t("tab_settings", "Settings"), model.tab == .settings ? "gearshape.fill" : "gearshape")
            }
            .accessibilityIdentifier("tab-settings")
        }
        .tint(.raftTextPrimary)
    }

    /// The tab bar fills symbols by itself; `.none` keeps the outline for unselected tabs
    /// (only the selected one asks for `.fill`).
    private func tabLabel(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol).environment(\.symbolVariants, .none)
        }
    }
}

/// The Activity tab's icon while there is unread activity (§2.11): the tab's waveform with an
/// 8×8 pink square, 1pt ink ring, at its top-right. Drawn into an `.alwaysOriginal` bitmap (the
/// tab bar would tint a template image, and its own badge is a round number capsule), with a
/// selected and an unselected variant per appearance. The bar itself stays native.
enum ActivityTabImage {
    @MainActor private static var cache: [String: UIImage] = [:]

    @MainActor static func image(selected: Bool, dark: Bool, scale: CGFloat) -> UIImage {
        let key = "\(selected)|\(dark)|\(scale)"
        if let hit = cache[key] { return hit }
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        // Selected: the TabView tint (raftTextPrimary); unselected: the bar's default label color.
        let color = selected ? UIColor(Color.raftTextPrimary).resolvedColor(with: traits) : UIColor.label.resolvedColor(with: traits)
        let config = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
            .applying(UIImage.SymbolConfiguration(weight: .medium))
        guard let symbol = UIImage(systemName: "waveform.path.ecg", withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return UIImage() }
        let glyph = symbol.size
        // Pad every side by the dot's overhang so the waveform stays centered in the item.
        let dot: CGFloat = 8
        let overhang: CGFloat = 4
        let canvas = CGSize(width: glyph.width + overhang * 2, height: glyph.height + overhang * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            symbol.draw(in: CGRect(x: overhang, y: overhang, width: glyph.width, height: glyph.height))
            let rect = CGRect(x: canvas.width - dot - 0.5, y: 0.5, width: dot, height: dot)
            let square = UIBezierPath(roundedRect: rect, cornerRadius: 2)
            UIColor(Color.raftPink).setFill()
            square.fill()
            square.lineWidth = 1
            UIColor(Color.raftInk).setStroke()
            square.stroke()
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
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
                .hidesTabBarWhenPushed()
        case .thread(let ref):
            ThreadView(store: workspace.thread(for: ref))
                .hidesTabBarWhenPushed()
        case .servers:
            ServerPickerView(showsBack: true)
        case .saved:
            SavedView()
        case .browseChannels:
            BrowseChannelsView()
        case .channelInfo(let channelId):
            ChannelInfoView(channelId: channelId)
        case .channelMembers(let channelId):
            ChannelMembersView(channelId: channelId)
        case .messageSearch:
            MessageSearchDestination()
        }
    }
}
