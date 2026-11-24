import SwiftUI
import UserNotifications

// MARK: 19 / 20 Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("raft.notifications.device") private var deviceNotifications = false
    @AppStorage("raft.notifications.previews") private var showPreviews = true
    @AppStorage("raft.notifications.pausedUntil") private var pausedUntil: Double = 0
    @State private var systemDenied = false
    @State private var twoStepEnabled: Bool?
    @State private var webPage: URL?
    @State private var showsSwitcher = false
    @State private var confirmingSignOut = false
    @State private var copyTick = 0
    #if DEBUG
    @State private var showsDiagnostics = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileCard
                    .padding(.top, 6)
                notificationsGroup
                accountGroup
                aboutGroup
                RaftGroupCard {
                    DangerTextButton(title: L10n.t("settings_account_logout", "Sign out")) {
                        confirmingSignOut = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .accessibilityIdentifier("settings-sign-out")
                }
                .padding(.top, 20)
                #if DEBUG
                developerGroup
                #endif
                MadeWithAirBuild()
                    .padding(.top, 28)
                    .padding(.bottom, 16)
            }
        }
        .background(Color.raftCanvasWarm.ignoresSafeArea())
        .raftNavigationTitle(L10n.t("settings_title", "Settings"))
        .safariSheet($webPage)
        .alert(L10n.t("ios_signout_title", "Sign out of Raft?"), isPresented: $confirmingSignOut) {
            Button(L10n.t("common_cancel", "Cancel"), role: .cancel) {}
            Button(L10n.t("settings_account_logout_action", "Sign out"), role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text(L10n.t("ios_signout_message", "You’ll need to sign in again to see your servers on this iPhone. Drafts that haven’t been sent will be lost."))
        }
        .sensoryFeedback(.success, trigger: copyTick)
        .task { await refreshNotificationStatus() }
        .task(id: webPage == nil) {
            guard webPage == nil else { return }
            await loadTwoStep()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationStatus() } }
        }
        #if DEBUG
        .sheet(isPresented: $showsDiagnostics) { DebugCoreView() }
        #endif
    }

    // MARK: Profile

    private var me: Persona {
        let user = model.session.user
        let name = user?.displayName ?? user?.name ?? ""
        if let workspace = model.workspace {
            return workspace.directory.persona(type: "user", id: user?.id ?? "", name: name, avatarURL: user?.avatarUrl)
        }
        return .human(id: user?.id ?? "", name: name, avatarURL: user?.avatarUrl)
    }

    private var profileCard: some View {
        let user = model.session.user
        return Button {
            webPage = model.webURL("settings/account")
        } label: {
            HStack(spacing: 14) {
                AvatarView(persona: me, size: .lg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: me.name)
                        .raftFont(.navTitle)
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                    if let email = user?.email {
                        Text(verbatim: email)
                            .raftFont(.preview)
                            .foregroundStyle(Color.raftTextTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.raftTextDisabled)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .raftCardSurface(.card)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("settings-profile")
    }

    // MARK: Notifications

    private var notificationsGroup: some View {
        VStack(spacing: 0) {
            GroupTitle(text: L10n.t("settings_notifications_title", "Notifications"))
            RaftGroupCard {
                ToggleRow(
                    systemImage: "bell",
                    title: L10n.t("ios_settings_device_notifications", "Notifications on this device"),
                    isOn: Binding(get: { deviceNotifications && !systemDenied }, set: setDeviceNotifications)
                )
                .accessibilityIdentifier("settings-device-notifications")
                RowDivider(inset: 50)
                ToggleRow(
                    systemImage: "eye",
                    title: L10n.t("settings_notifications_show_previews_title", "Show message previews"),
                    isOn: $showPreviews
                )
                .accessibilityIdentifier("settings-previews")
                RowDivider(inset: 50)
                Menu {
                    Button(L10n.t("ios_pause_1h", "1 hour")) { pause(until: Date().addingTimeInterval(3600)) }
                    Button(L10n.t("ios_pause_tomorrow", "Until tomorrow")) { pause(until: tomorrowMorning) }
                    Button(L10n.t("settings_option_off", "Off")) { pausedUntil = 0 }
                } label: {
                    SettingsRowLabel(
                        systemImage: "moon",
                        title: L10n.t("settings_notifications_pause_title", "Pause notifications"),
                        value: pauseValue
                    )
                }
                .menuIndicator(.hidden)
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("settings-pause")
            }
        }
    }

    private var pauseValue: String {
        let until = Date(timeIntervalSince1970: pausedUntil)
        guard pausedUntil > 0, until > .now else { return L10n.t("settings_option_off", "Off") }
        return L10n.f("ios_paused_until", "Until %1$@", RaftFormat.clock(until))
    }

    private var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func pause(until date: Date) {
        pausedUntil = date.timeIntervalSince1970
    }

    /// On asks iOS for permission the first time; once the system says no, the switch stays off
    /// and opens the app's notification settings instead.
    private func setDeviceNotifications(_ on: Bool) {
        guard on else {
            deviceNotifications = false
            return
        }
        guard !systemDenied else {
            openSystemSettings(notifications: true)
            return
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            deviceNotifications = granted
            await refreshNotificationStatus()
            if !granted { openSystemSettings(notifications: true) }
        }
    }

    private func refreshNotificationStatus() async {
        guard !model.isPreview else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemDenied = settings.authorizationStatus == .denied
    }

    // MARK: Account

    private var accountGroup: some View {
        VStack(spacing: 0) {
            GroupTitle(text: L10n.t("settings_account_title", "Account"))
            RaftGroupCard {
                Button {
                    showsSwitcher = true
                } label: {
                    SettingsRowLabel(
                        systemImage: "server.rack",
                        title: L10n.t("settings_server_title", "Server"),
                        value: model.servers.selectedServer?.name
                    )
                }
                .buttonStyle(RowButtonStyle())
                .popover(isPresented: $showsSwitcher, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    ServerSwitcher(isPresented: $showsSwitcher) {
                        showsSwitcher = false
                        model.push(.servers)
                    }
                    .presentationCompactAdaptation(.popover)
                }
                .accessibilityIdentifier("settings-server")
                RowDivider(inset: 50)
                Button {
                    openSystemSettings(notifications: false)
                } label: {
                    SettingsRowLabel(
                        systemImage: "translate",
                        title: L10n.t("settings_language_region_title", "Language & region"),
                        value: languageName
                    )
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("settings-language")
                RowDivider(inset: 50)
                Button {
                    webPage = twoStepURL
                } label: {
                    SettingsRowLabel(
                        systemImage: "checkmark.shield",
                        title: L10n.t("settings_account_two_step_title", "Two-step verification"),
                        value: twoStepEnabled.map { $0 ? L10n.t("settings_option_on", "On") : L10n.t("settings_option_off", "Off") }
                    )
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("settings-two-step")
            }
        }
    }

    /// The language the app is showing, named in that language's own words for the current locale.
    private var languageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// `settings/account#two-step` on the web app.
    private var twoStepURL: URL {
        let base = model.webURL("settings/account")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.fragment = "two-step"
        return components?.url ?? base
    }

    private func loadTwoStep() async {
        guard !model.isPreview else { return }
        if let value = try? await model.core.api.secondFactorEnabled() {
            twoStepEnabled = value
        }
    }

    private func openSystemSettings(notifications: Bool) {
        let string = notifications ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
        if let url = URL(string: string) { UIApplication.shared.open(url) }
    }

    // MARK: About

    private var versionText: String {
        "\(AppInfo.current.version) (\(AppInfo.current.build))"
    }

    private var aboutGroup: some View {
        VStack(spacing: 0) {
            GroupTitle(text: L10n.t("settings_about_title", "About"))
            RaftGroupCard {
                SettingsRowLabel(
                    systemImage: "info.circle",
                    title: L10n.t("settings_about_label_version", "Version"),
                    value: versionText,
                    valueMono: true,
                    chevron: false
                )
                .onLongPressGesture(minimumDuration: 0.4) { copyVersion() }
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(L10n.t("settings_about_version_copy_hint", "Long press to copy")))
                .accessibilityAction(named: Text(L10n.t("common_copy", "Copy"))) { copyVersion() }
                .accessibilityIdentifier("settings-version")
            }
        }
    }

    private func copyVersion() {
        UIPasteboard.general.string = versionText
        copyTick += 1
        model.showToast(L10n.t("common_copied", "Copied"))
    }

    // MARK: Developer (DEBUG builds only)

    #if DEBUG
    private var developerGroup: some View {
        VStack(spacing: 0) {
            GroupTitle(text: "Developer")
            RaftGroupCard {
                ToggleRow(
                    systemImage: "lock.shield",
                    title: "Read-only mode",
                    isOn: Binding(get: { model.preferences.readOnly }, set: { model.preferences.readOnly = $0 })
                )
                .accessibilityIdentifier("settings-read-only")
                RowDivider(inset: 50)
                Button {
                    showsDiagnostics = true
                } label: {
                    SettingsRowLabel(systemImage: "stethoscope", title: "Core diagnostics")
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("settings-diagnostics")
            }
        }
    }
    #endif
}

/// A settings group's title above its card (§3-19).
private struct GroupTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .raftFont(.footnoteStrong)
            .foregroundStyle(Color.raftTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            .padding(.horizontal, 20)
            .padding(.bottom, 7)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Icon, title and the Raft switch.
private struct ToggleRow: View {
    let systemImage: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.raftTextSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .raftFont(.rowTitleMedium)
                    .foregroundStyle(Color.raftTextPrimary)
            }
        }
        .toggleStyle(RaftToggleStyle())
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }
}
