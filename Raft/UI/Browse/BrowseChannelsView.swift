import SwiftUI

// MARK: 06c Home entry

/// Home's last Channels row: opens Browse channels. Its magnifier box matches the 32×32
/// channel tiles above it (corner 6), so the name starts at x=58 like theirs.
struct BrowseEntryRow: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    var body: some View {
        HStack(spacing: 12) {
            let size = min(side, 51)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.raftCard)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.raftInk, lineWidth: 1.5))
                .overlay {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.raftTextSecondary)
                }
                .frame(width: size, height: size)
                .dieCut(radius: 6)
                .accessibilityHidden(true)
            Text(L10n.t("ios_browse_title", "Browse channels"))
                .raftFont(.rowTitleMedium)
                .foregroundStyle(Color.raftTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.raftTextTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("ios_browse_title", "Browse channels")))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: 25 Browse channels

struct BrowseChannelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @State private var query = ""
    @State private var showsSkeleton = false
    @State private var showsBanner = false
    @State private var retrying = false

    private var list: ChannelListStore { workspace.channelList }
    private var groups: BrowseGroups { list.browseGroups(query: query) }
    private var hasData: Bool { list.phase == .loaded || !list.channels.isEmpty }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                content
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.raftCanvasWarm.ignoresSafeArea())
        .raftNavigationTitle(L10n.t("ios_browse_title", "Browse channels"), subtitle: model.servers.selectedServer?.displayName)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(L10n.t("tasks_search_channels", "Search channels")))
        .refreshable { await list.refresh() }
        .safeAreaBar(edge: .top, spacing: 0) {
            if showsBanner {
                StatusBanner(updatedAt: workspace.lastConnectedAt)
                    .padding(.vertical, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: showsBanner)
        .task {
            if list.phase != .loaded && list.phase != .loading { await list.refresh() }
        }
        .task(id: hasData) {
            showsSkeleton = false
            guard !hasData else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsSkeleton = true }
        }
        .task(id: workspace.isOffline) {
            guard workspace.isOffline else {
                showsBanner = false
                return
            }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, workspace.isOffline else { return }
            showsBanner = true
        }
        .onChange(of: searching && groups.isEmpty && hasData) { _, empty in
            guard empty else { return }
            AccessibilityNotification.Announcement(L10n.f("ios_browse_empty_title", "No channels match “%1$@”", query)).post()
        }
    }

    @ViewBuilder private var content: some View {
        if hasData {
            loaded
        } else if case .failed = list.phase {
            RaftGroupCard {
                InlineRetryRow(title: L10n.t("ios_browse_load_failed", "Couldn’t load channels."), retrying: retrying) {
                    retry()
                }
            }
            .padding(.top, 20)
            .accessibilityIdentifier("browse-error")
        } else if showsSkeleton {
            BrowseSkeleton()
        }
    }

    @ViewBuilder private var loaded: some View {
        let groups = self.groups
        if searching && groups.isEmpty {
            BrowseEmptyResult(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            if !groups.notJoined.isEmpty {
                SectionHeader(title: L10n.t("search_not_joined", "Not joined"), count: groups.notJoined.count)
                group(groups.notJoined)
            }
            if !groups.joined.isEmpty {
                SectionHeader(title: L10n.t("ios_browse_joined", "Joined"), count: groups.joined.count)
                group(groups.joined)
            }
        }
        Color.clear.frame(height: 24)
    }

    private func group(_ channels: [Channel]) -> some View {
        RaftGroupCard {
            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                if index > 0 { RowDivider(inset: 53) }
                NavigationLink(value: AppRoute.conversation(ConversationRef(channelId: channel.id, title: channel.name, kind: .channel, lastReadSeq: channel.maxReadSeq))) {
                    BrowseChannelRow(channel: channel, query: query, memberCount: list.memberCount(channel.id))
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("browse-row-\(channel.name)")
                .task(id: channel.id) { await list.loadMemberCount(channel.id) }
            }
        }
    }

    private func retry() {
        guard !retrying else { return }
        retrying = true
        Task {
            await list.refresh()
            retrying = false
        }
    }
}

/// "N members" (one / other).
enum MemberCountText {
    static func text(_ count: Int) -> String {
        count == 1
            ? L10n.f("members_counts_members_one", "%1$d member", count)
            : L10n.f("members_counts_members_other", "%1$d members", count)
    }
}

/// One channel of Browse (62 high): tile, name with the search match in bold, topic and count,
/// a chevron (not joined) or "Joined ✓".
struct BrowseChannelRow: View {
    let channel: Channel
    var query = ""
    var memberCount: Int?

    private var topic: String? {
        guard let text = channel.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return PlainText.preview(text)
    }

    var body: some View {
        HStack(spacing: 12) {
            ChannelTile(isPrivate: channel.isPrivate)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.highlighted(channel.name, query: query))
                    .foregroundStyle(Color.raftTextPrimary)
                    .lineLimit(1)
                if topic != nil || memberCount != nil {
                    HStack(spacing: 4) {
                        if let topic {
                            Text(verbatim: topic)
                                .raftFont(.preview)
                                .foregroundStyle(Color.raftTextSecondary)
                                .lineLimit(1)
                                .layoutPriority(0)
                        }
                        if let memberCount {
                            Text(verbatim: (topic == nil ? "" : "· ") + MemberCountText.text(memberCount))
                                .raftFont(.monoCaption)
                                .foregroundStyle(Color.raftTextTertiary)
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            if channel.joined {
                HStack(spacing: 4) {
                    Text(L10n.t("ios_browse_joined", "Joined"))
                        .raftFont(.caption)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.raftTextTertiary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.raftTextDisabled)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.accessibilityLabel(channel, topic: topic, memberCount: memberCount)))
        .accessibilityHint(Text(channel.joined ? L10n.t("ios_browse_hint_open", "Open channel") : L10n.t("ios_browse_hint_preview", "Preview channel")))
        .accessibilityAddTraits(.isButton)
    }

    /// "research, <topic>, 18 members" (+ ", joined").
    static func accessibilityLabel(_ channel: Channel, topic: String?, memberCount: Int?) -> String {
        var parts = [channel.name]
        if let topic { parts.append(topic) }
        if let memberCount { parts.append(MemberCountText.text(memberCount)) }
        if channel.joined { parts.append(L10n.t("ios_browse_joined", "Joined").lowercased()) }
        return parts.joined(separator: ", ")
    }

    /// The name in Medium with the matched part in Bold (25b).
    static func highlighted(_ name: String, query: String) -> AttributedString {
        var text = AttributedString(name)
        text.font = RaftFont.rowTitleMedium.font
        if let range = BrowseGroups.matchRange(in: name, query: query),
           let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            text[lower..<upper].font = RaftFont.rowTitleMedium.weighted(.bold, groteskName: RaftFont.bold)
        }
        return text
    }
}

/// 25c: no channel matches the search.
struct BrowseEmptyResult: View {
    let query: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.raftTextTertiary)
                .accessibilityHidden(true)
                .padding(.bottom, 14)
            Text(L10n.f("ios_browse_empty_title", "No channels match “%1$@”", query))
                .font(.custom(RaftFont.bold, size: 20, relativeTo: .title3))
                .lineSpacing(26 - 20 * 1.276)
                .foregroundStyle(Color.raftTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Text(L10n.t("ios_browse_empty_detail", "Check the spelling or ask an admin to add you."))
                .raftFont(.preview)
                .foregroundStyle(Color.raftTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 120)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browse-empty")
    }
}

/// 25 skeleton: a header block and one card of six rows.
struct BrowseSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock(width: 72, height: 12).padding(.leading, 20).padding(.top, 26).padding(.bottom, 10)
            RaftGroupCard {
                ForEach(Array([90, 70, 110, 84, 96, 64].enumerated()), id: \.offset) { index, width in
                    if index > 0 { RowDivider(inset: 53) }
                    HStack(spacing: 12) {
                        SkeletonBlock(width: 27, height: 27)
                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonBlock(width: CGFloat(width), height: 14)
                            SkeletonBlock(width: CGFloat(width + 110), height: 10)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 62)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("ios_loading", "Loading")))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("browse-skeleton")
    }
}

/// A card row saying something did not load, with Retry (the whole row is the button).
struct InlineRetryRow: View {
    let title: String
    var retrying = false
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.raftDanger)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .raftFont(.rowTitleMedium)
                    .foregroundStyle(Color.raftTextPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if retrying {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Text(L10n.t("common_retry", "Retry"))
                        .font(.custom(RaftFont.semibold, size: 15, relativeTo: .subheadline))
                        .underline(true, color: Color.raftTextPrimary)
                        .foregroundStyle(Color.raftTextPrimary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(retrying)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(retrying ? Text(L10n.t("ios_loading", "Loading")) : Text(verbatim: ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(L10n.t("common_retry", "Retry")))
        .accessibilityIdentifier("inline-retry")
    }
}
