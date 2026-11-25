import SwiftUI

// MARK: 05 / 05b Servers

struct ServerPickerView: View {
    /// Pushed from Home's switcher (back shown) or the sign-in flow (no back: already signed in).
    var showsBack: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var safariURL: URL?

    private var servers: [AuthServer] {
        model.servers.servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            if servers.isEmpty {
                empty
            } else {
                list
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { pinnedSignOut }
        .background(Color.raftCanvasWarm.ignoresSafeArea())
        .raftNavigationTitle(L10n.t("auth_server_title_choose", "Choose server"))
        .navigationBarBackButtonHidden(!showsBack)
        .safariSheet($safariURL)
        .refreshable { await model.servers.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.servers.reload() } }
        }
    }

    private var signedInAs: some View {
        let email = model.session.user?.email ?? model.session.user?.visibleName ?? ""
        return Text.emphasized(L10n.t("auth_server_signed_in_as", "Signed in as %1$@"), email, base: .preview, strongFont: RaftFont.semibold, strongColor: .raftTextPrimary)
            .foregroundStyle(Color.raftTextSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            signedInAs
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            RaftGroupCard {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { RowDivider(inset: 61) }
                    Button {
                        Task {
                            await model.selectServer(server.id)
                            if showsBack {
                                model.showsServerPicker = false
                                dismiss()
                            }
                        }
                    } label: {
                        ServerRow(server: server, selected: showsBack && server.id == model.servers.selectedServerId)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("server-row-\(index)")
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// 05: Sign out is pinned to the bottom, 24pt above the home indicator, however short the
    /// list is (05b keeps it under the empty state).
    @ViewBuilder private var pinnedSignOut: some View {
        if !showsBack, !servers.isEmpty {
            DangerTextButton(title: L10n.t("settings_account_logout", "Sign out")) {
                Task { await model.signOut() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            // The 44pt button ends 24pt above the home indicator (safe-area bottom − 4).
            .padding(.bottom, 4)
            .background(Color.raftCanvasWarm.ignoresSafeArea(edges: .bottom))
            .accessibilityIdentifier("sign-out")
        }
    }

    private var empty: some View {
        VStack(spacing: 0) {
            ServersIllustration()
                .padding(.bottom, 22)
                .accessibilityHidden(true)
            Text(L10n.t("ios_servers_empty_title", "You’re not in any server yet"))
                .raftFont(.emptyTitle)
                .foregroundStyle(Color.raftTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Text(L10n.t("ios_servers_empty_detail", "Ask a teammate for an invite link, or create a server on the web. Servers hold your channels, agents and activity."))
                .raftFont(.callout)
                .foregroundStyle(Color.raftTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 20)
            PrimaryButton(title: L10n.t("ios_open_web", "Open Raft on the web"), systemImage: "safari") {
                safariURL = model.environment.webURL
            }
            .accessibilityIdentifier("open-web")
            signedInAs.padding(.top, 20)
            DangerTextButton(title: L10n.t("settings_account_logout", "Sign out")) {
                Task { await model.signOut() }
            }
            .padding(.top, 8)
            .accessibilityIdentifier("sign-out")
        }
        .padding(.horizontal, 32)
        .padding(.top, 72)
    }
}

struct ServerRow: View {
    let server: AuthServer
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            ServerAvatar(name: server.name, side: 35)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: server.displayName)
                    .raftFont(.rowTitle)
                    .foregroundStyle(Color.raftTextPrimary)
                    .lineLimit(1)
                if let slug = server.slug, !slug.isEmpty {
                    Text(verbatim: "/\(slug)")
                        .raftFont(.monoCaption)
                        .foregroundStyle(Color.raftTextTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected {
                SelectionMark()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.raftTextDisabled)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [server.displayName, server.slug.map { "/\($0)" }].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The yellow check square of the current server (06b).
struct SelectionMark: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        shape.fill(Color.raftYellow)
            .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
            .overlay { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.raftInk) }
            .frame(width: 22, height: 22)
            .dieCut()
            .accessibilityHidden(true)
    }
}

/// Three letter stickers: B (stone, −8°), ? (yellow, hard shadow, on top), R (lavender, +8°).
struct ServersIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            letter("B", .raftStone).rotationEffect(.degrees(-8)).offset(x: 0, y: 18)
            letter("R", .raftLavender).rotationEffect(.degrees(8)).offset(x: 64, y: 18)
            letter("?", .raftYellow).hardShadow(3).offset(x: 32, y: 0)
        }
        .frame(width: 120, height: 84, alignment: .topLeading)
    }

    private func letter(_ text: String, _ color: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return shape.fill(color)
            .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
            .overlay { Text(verbatim: text).font(.custom(RaftFont.bold, size: 24)).foregroundStyle(Color.raftInk) }
            .frame(width: 56, height: 56)
            .dieCut()
    }
}
