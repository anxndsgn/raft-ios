import SwiftUI

/// The members of one channel as a screen loads them (Channel info and the full list).
@MainActor
@Observable
final class ChannelMembersModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded([ChannelMember])
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var retrying = false

    var members: [ChannelMember] {
        if case .loaded(let list) = phase { return list }
        return []
    }

    func load(_ channelId: String, workspace: Workspace) async {
        if case .loaded = phase { return }
        await read(channelId, workspace: workspace)
    }

    func retry(_ channelId: String, workspace: Workspace) {
        guard !retrying else { return }
        retrying = true
        Task {
            await read(channelId, workspace: workspace)
            retrying = false
        }
    }

    private func read(_ channelId: String, workspace: Workspace) async {
        if !retrying { phase = .loading }
        do {
            phase = .loaded(try await workspace.channelMembers(channelId))
        } catch {
            phase = .failed
        }
    }
}

// MARK: 27 Channel info

struct ChannelInfoView: View {
    let channelId: String
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @State private var members = ChannelMembersModel()
    @State private var topicExpanded = false
    @State private var confirmingLeave = false
    @State private var leaving = false
    @State private var showsMembersSkeleton = false
    @State private var successTick = 0
    @State private var errorTick = 0

    private var channel: Channel? { workspace.channelList.channel(id: channelId) }
    private var name: String { channel?.name ?? "" }
    private var isPreview: Bool { workspace.channelList.isPreview(channelId) }
    private var memberCount: Int? {
        if case .loaded(let list) = members.phase { return list.count }
        return workspace.channelList.memberCount(channelId)
    }

    private var topic: String? {
        guard let text = channel?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return PlainText.preview(text)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                settingsCard
                membersSection
                if let channel, channel.canLeave, !isPreview {
                    leaveCard.padding(.top, 20)
                }
                Color.clear.frame(height: 24)
            }
        }
        .background(Color.raftCanvasWarm.ignoresSafeArea())
        .raftNavigationTitle(L10n.t("ios_channel_info_title", "Channel info"))
        .confirmationDialog(
            L10n.f("ios_leave_confirm_title", "Leave %1$@?", "#\(name)"),
            isPresented: $confirmingLeave,
            titleVisibility: .visible
        ) {
            Button(L10n.t("channel_settings_leave", "Leave channel"), role: .destructive) { leave() }
            Button(L10n.t("common_cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(channel?.isPrivate == true
                ? L10n.t("ios_leave_confirm_private", "You’ll need an invite to rejoin this private channel.")
                : L10n.t("ios_leave_confirm_public", "You can rejoin from Browse channels anytime."))
        }
        .sensoryFeedback(.success, trigger: successTick)
        .sensoryFeedback(.error, trigger: errorTick)
        .task { await members.load(channelId, workspace: workspace) }
        .task(id: members.phase == .loading) {
            showsMembersSkeleton = false
            guard members.phase == .loading else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsMembersSkeleton = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            ChannelTile(isPrivate: channel?.isPrivate ?? false, large: true)
                .padding(.bottom, 14)
            Text("\(Text(verbatim: "# ").foregroundStyle(Color.raftTextTertiary))\(Text(verbatim: name).foregroundStyle(Color.raftTextPrimary))")
                .font(.custom(RaftFont.semibold, size: 22, relativeTo: .title2))
                .lineSpacing(28 - 22 * 1.276)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let topic {
                Text(verbatim: topic)
                    .raftFont(.preview)
                    .foregroundStyle(Color.raftTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(topicExpanded ? nil : 3)
                    .padding(.top, 6)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { topicExpanded.toggle() } }
            }
            if let created = createdLine {
                Text(verbatim: created)
                    .raftFont(.caption)
                    .foregroundStyle(Color.raftTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
    }

    /// "Created by XIN · Mar 4" (", 2025" in another year): only when the row names a creator.
    private var createdLine: String? {
        guard let channel, let creator = channel.createdByName, !creator.isEmpty,
              let date = RaftDate.parse(channel.createdAt) else { return nil }
        return L10n.f("ios_channel_info_created", "Created by %1$@ · %2$@", creator, Self.createdDate(date))
    }

    static func createdDate(_ date: Date, now: Date = Date()) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    // MARK: Settings

    private var settingsCard: some View {
        RaftGroupCard {
            if !isPreview {
                HStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.raftTextSecondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Toggle(isOn: muteBinding) {
                        Text(L10n.t("ios_channel_info_mute", "Mute channel"))
                            .raftFont(.rowTitleMedium)
                            .foregroundStyle(Color.raftTextPrimary)
                    }
                    .tint(.raftYellow)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .accessibilityIdentifier("channel-info-mute")
                RowDivider(inset: 50)
            }
            NavigationLink(value: AppRoute.channelMembers(channelId)) {
                SettingsRowLabel(systemImage: "person.2", title: L10n.t("channel_settings_members", "Members"), value: memberCount.map(String.init), valueMono: true)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityIdentifier("channel-info-members")
        }
    }

    private var muteBinding: Binding<Bool> {
        Binding {
            channel?.activityMuted ?? false
        } set: { muted in
            Task {
                do {
                    try await workspace.setChannelMuted(channelId, muted: muted)
                } catch {
                    model.showToast(ErrorText.describe(error))
                }
            }
        }
    }

    // MARK: Members

    @ViewBuilder private var membersSection: some View {
        SectionHeader(title: L10n.t("channel_settings_members", "Members"), count: memberCount, top: 18)
        switch members.phase {
        case .idle, .loading:
            if showsMembersSkeleton { MembersSkeleton() }
        case .failed:
            RaftGroupCard {
                InlineRetryRow(title: L10n.t("ios_channel_info_members_failed", "Couldn’t load members."), retrying: members.retrying) {
                    members.retry(channelId, workspace: workspace)
                }
            }
        case .loaded(let list):
            if !list.isEmpty {
                RaftGroupCard {
                    ForEach(Array(list.prefix(5).enumerated()), id: \.element.id) { index, member in
                        if index > 0 { RowDivider(inset: 58) }
                        ChannelMemberRow(member: member, persona: persona(member))
                    }
                    if list.count > 5 {
                        RowDivider(inset: 14)
                        NavigationLink(value: AppRoute.channelMembers(channelId)) {
                            HStack {
                                Text(L10n.f("ios_channel_info_see_all", "See all %1$d", list.count))
                                    .font(.custom(RaftFont.semibold, size: 15, relativeTo: .subheadline))
                                    .underline(true, color: Color.raftTextPrimary)
                                    .foregroundStyle(Color.raftTextPrimary)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.raftTextDisabled)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityIdentifier("channel-info-see-all")
                    }
                }
            }
        }
    }

    private func persona(_ member: ChannelMember) -> Persona {
        workspace.directory.persona(type: member.kind == .agent ? "agent" : "user", id: member.id, name: member.visibleName, avatarURL: member.avatarUrl)
    }

    // MARK: Leave

    private var leaveCard: some View {
        RaftGroupCard {
            Button {
                confirmingLeave = true
            } label: {
                ZStack {
                    if leaving {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Text(L10n.t("channel_settings_leave", "Leave channel"))
                            .font(.custom(RaftFont.semibold, size: 16, relativeTo: .body))
                            .foregroundStyle(Color.raftDanger)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .disabled(leaving)
            .accessibilityLabel(Text(L10n.t("channel_settings_leave", "Leave channel")))
            .accessibilityIdentifier("channel-info-leave")
        }
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true
        Task {
            do {
                try await workspace.leaveChannel(channelId)
                leaving = false
                successTick += 1
                model.popToRoot()
            } catch {
                leaving = false
                errorTick += 1
                model.showToast(L10n.t("ios_leave_failed", "Couldn’t leave. Try again."))
            }
        }
    }
}

/// A member of a channel (48 high): avatar, name, "Agent" tag. Not a button.
struct ChannelMemberRow: View {
    let member: ChannelMember
    let persona: Persona

    var body: some View {
        // 27: avatar 32 (an agent's with its 10×10 presence light, as on Home and in New
        // message) · name at x=58 · Spacer · the Agent tag at the right edge.
        HStack(spacing: 12) {
            AvatarView(persona: persona, size: .row, showsPresence: member.kind == .agent, ringColor: .raftCard)
            Text(verbatim: persona.name)
                .raftFont(.rowTitleMedium)
                .foregroundStyle(Color.raftTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if member.kind == .agent {
                Text(L10n.t("member_label_agent", "Agent"))
                    .raftFont(.monoSmall)
                    .foregroundStyle(Color.raftTextSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.raftTextTertiary, lineWidth: 1))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

/// Five member rows while the list loads.
struct MembersSkeleton: View {
    var body: some View {
        RaftGroupCard {
            ForEach(Array([90, 70, 110, 84, 60].enumerated()), id: \.offset) { index, width in
                if index > 0 { RowDivider(inset: 58) }
                HStack(spacing: 12) {
                    SkeletonBlock(width: 32, height: 32)
                    SkeletonBlock(width: CGFloat(width), height: 14)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("ios_loading", "Loading")))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: Full member list

struct ChannelMembersView: View {
    let channelId: String
    @Environment(Workspace.self) private var workspace
    @State private var members = ChannelMembersModel()
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var showsSkeleton = false

    private var filtered: [ChannelMember] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return members.members }
        return members.members.filter {
            $0.visibleName.range(of: needle, options: .caseInsensitive) != nil || $0.name.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch members.phase {
                case .idle, .loading:
                    if showsSkeleton { MembersSkeleton().padding(.top, 16) }
                case .failed:
                    RaftGroupCard {
                        InlineRetryRow(title: L10n.t("ios_channel_info_members_failed", "Couldn’t load members."), retrying: members.retrying) {
                            members.retry(channelId, workspace: workspace)
                        }
                    }
                    .padding(.top, 16)
                case .loaded:
                    let list = filtered
                    SectionHeader(title: L10n.t("channel_settings_members", "Members"), count: list.count, top: 18)
                    if !list.isEmpty {
                        RaftGroupCard {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, member in
                                if index > 0 { RowDivider(inset: 58) }
                                ChannelMemberRow(member: member, persona: workspace.directory.persona(
                                    type: member.kind == .agent ? "agent" : "user", id: member.id, name: member.visibleName, avatarURL: member.avatarUrl
                                ))
                            }
                        }
                    }
                }
                Color.clear.frame(height: 24)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.raftCanvasWarm.ignoresSafeArea())
        .safeAreaBar(edge: .top, spacing: 0) {
            SearchHeader(
                text: $query,
                prompt: L10n.t("ios_members_search", "Search members"),
                focus: $searchFocused,
                submit: {},
                close: {
                    query = ""
                    searchFocused = false
                },
                closeWhileFocused: true,
                solid: true
            )
        }
        // After the search bar: with the vertical bar the title block goes above it.
        .raftNavigationTitle(L10n.t("channel_settings_members", "Members"), subtitle: workspace.channelList.channel(id: channelId).map { "#\($0.name)" })
        .task { await members.load(channelId, workspace: workspace) }
        .task(id: members.phase == .loading) {
            showsSkeleton = false
            guard members.phase == .loading else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsSkeleton = true }
        }
    }
}
