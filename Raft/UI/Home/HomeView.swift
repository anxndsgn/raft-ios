import SwiftUI

// MARK: 06 / 07 / 08 Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @State private var showsSwitcher = false
    @State private var layout: HomeLayout?
    @State private var showsBanner = false
    @State private var showsSkeleton = false
    /// New message (28), from the Direct messages header (06d).
    @State private var showsNewMessage = false
    /// The search button the search page zooms out of (06e).
    @Namespace private var searchZoom

    private var list: ChannelListStore { workspace.channelList }
    private var extras: HomeExtrasStore { workspace.homeExtras }
    private var server: AuthServer? { model.servers.selectedServer }

    var body: some View {
        ScrollView {
            content
                .animation(.easeInOut(duration: 0.2), value: list.phase)
        }
        .background(Color.raftCanvasWarm.ignoresSafeArea())
        .navigationTitle(Text(L10n.t("tab_home", "Home")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsBanner {
                StatusBanner(updatedAt: workspace.lastConnectedAt ?? list.lastLoadedAt)
                    .padding(.vertical, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(showsBanner ? .easeOut(duration: 0.25) : .easeIn(duration: 0.2), value: showsBanner)
        .refreshable {
            await list.refresh()
            await extras.load()
            relayout()
        }
        .onAppear {
            relayout()
            MessageSearchZoom.namespace = searchZoom
        }
        .newMessageSheet(isPresented: $showsNewMessage)
        .onChange(of: list.phase) { relayout() }
        .onChange(of: rowIdentity) { relayout(keepUnread: true) }
        .task(id: workspace.isOffline) {
            guard workspace.isOffline else {
                showsBanner = false
                return
            }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, workspace.isOffline else { return }
            showsBanner = true
            AccessibilityNotification.Announcement(L10n.t("ios_reconnecting", "Reconnecting…")).post()
        }
        .task(id: list.phase == .loading) {
            // The skeleton only after 300ms without data (§4).
            showsSkeleton = false
            guard list.phase == .loading else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsSkeleton = true }
        }
        .task(id: unreadSignature) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !unreadSignature.isEmpty else { return }
            await extras.loadPreviews()
        }
    }

    // MARK: Layout snapshot

    /// Which conversations sit in Unread vs the lists, fixed while the page is on screen (§3-06).
    private func relayout(keepUnread: Bool = false) {
        guard list.phase == .loaded else { return }
        let attention = (list.channelRows + list.directMessageRows)
            .filter { $0.priority != .quiet }
            .sorted(by: HomeRow.homeOrder)
            .map(\.id)
        if keepUnread, let layout {
            let added = attention.filter { !layout.unreadIds.contains($0) }
            self.layout = HomeLayout(unreadIds: added + layout.unreadIds)
        } else {
            layout = HomeLayout(unreadIds: attention)
        }
    }

    private var rowIdentity: [String] {
        (list.channelRows + list.directMessageRows).map(\.id).sorted()
    }

    private var unreadSignature: String {
        (list.channelRows + list.directMessageRows).filter { $0.priority != .quiet }
            .map { "\($0.id):\($0.unreadCount):\($0.threadUnreadCount)" }.joined(separator: ",")
    }

    private var unreadRows: [HomeRow] {
        let ids = layout?.unreadIds ?? []
        return ids.compactMap { list.row(id: $0) }
    }

    private var channelRows: [HomeRow] {
        let unread = Set(layout?.unreadIds ?? [])
        return list.channelRows.filter { !unread.contains($0.id) }.sorted(by: Self.recent)
    }

    private var dmRows: [HomeRow] {
        let unread = Set(layout?.unreadIds ?? [])
        return list.directMessageRows.filter { !unread.contains($0.id) }.sorted(by: Self.recent)
    }

    /// Most recent activity first (the lists below Unread).
    static func recent(_ lhs: HomeRow, _ rhs: HomeRow) -> Bool {
        switch (lhs.lastActivity, rhs.lastActivity) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch list.phase {
        case .idle, .loading:
            if showsSkeleton { HomeSkeleton() } else { Color.clear.frame(height: 1) }
        case .failed:
            LoadErrorView(title: L10n.t("home_error_load", "Could not load Home"), top: 72) {
                Task { await list.refresh() }
            }
        case .loaded:
            loaded
        }
    }

    private var loaded: some View {
        LazyVStack(spacing: 0) {
            chips
            if !unreadRows.isEmpty {
                SectionHeader(title: L10n.t("activity_filter_unread", "Unread"), count: unreadRows.filter { $0.priority != .quiet }.count) {
                    Button {
                        markAllRead()
                    } label: {
                        Text(L10n.t("inbox_action_mark_all_read", "Mark all read"))
                            .raftFont(.footnoteStrong)
                            .foregroundStyle(Color.raftTextSecondary)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mark-all-read")
                }
                unreadCards
            }
            // Always shown: Browse channels is its last row, even with no channel joined (06c).
            SectionHeader(title: L10n.t("home_section_channels", "Channels"), count: channelRows.count)
            RaftGroupCard {
                ForEach(Array(channelRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { RowDivider(inset: 53) }
                    rowButton(row) { ChannelRowView(row: row) }
                }
                if !channelRows.isEmpty { RowDivider(inset: 53) }
                NavigationLink(value: AppRoute.browseChannels) {
                    BrowseEntryRow()
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityHint(Text(L10n.f("ios_browse_hint", "Find and join channels in %1$@", server?.name ?? "")))
                .accessibilityIdentifier("home-browse-channels")
            }
            // Shown without rows too: it holds the New message button (06d).
            SectionHeader(title: L10n.t("home_section_direct_messages", "Direct messages"), count: dmRows.isEmpty ? nil : dmRows.count) {
                NewMessageButton { showsNewMessage = true }
            }
            if !dmRows.isEmpty {
                RaftGroupCard {
                    ForEach(Array(dmRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider(inset: 61) }
                        rowButton(row) { DMRowView(row: row, persona: persona(for: row), selfNames: selfNames) }
                    }
                }
            }
            Color.clear.frame(height: 24)
        }
    }

    private func rowButton<Label: View>(_ row: HomeRow, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: AppRoute.conversation(ref(for: row))) {
            label()
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu { rowMenu(row) }
        .accessibilityIdentifier("home-row-\(row.title)")
    }

    @ViewBuilder private func rowMenu(_ row: HomeRow) -> some View {
        if row.unreadCount > 0 || row.threadUnreadCount > 0 {
            Button {
                Task { await markRead([row.id]) }
            } label: {
                Label(L10n.t("ios_mark_as_read", "Mark as read"), systemImage: "checkmark.circle")
            }
        }
    }

    private func ref(for row: HomeRow) -> ConversationRef {
        ConversationRef(channelId: row.id, title: row.title, kind: row.conversationKind, lastReadSeq: row.maxReadSeq)
    }

    var selfNames: Set<String> {
        let user = model.session.user
        return Set([user?.displayName, user?.name].compactMap { $0 }.filter { !$0.isEmpty })
    }

    private func persona(for row: HomeRow) -> Persona {
        let dm = list.directMessages.first { $0.id == row.id }
        return workspace.directory.persona(type: row.peerType == "agent" ? "agent" : "user", id: dm?.peerId ?? row.id, name: row.title, avatarURL: row.avatarURL)
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                NavigationLink(value: AppRoute.saved) {
                    HomeChip(systemImage: "bookmark", title: L10n.t("home_nav_saved", "Saved")) {
                        // No number at 0 (30b); counts move with a save or removal (13.2).
                        if let count = extras.savedCount, count > 0 {
                            Text(verbatim: String(count)).raftFont(.monoCaption).foregroundStyle(Color.raftTextTertiary)
                                .contentTransition(.numericText(value: Double(count)))
                                .animation(.smooth(duration: 0.25), value: count)
                        }
                    }
                }
                .buttonStyle(CardButtonStyle())
                .accessibilityIdentifier("chip-saved")
                ForEach(pinnedRows) { row in
                    NavigationLink(value: AppRoute.conversation(ref(for: row))) {
                        HomeChip(systemImage: "pin", title: row.kind == .channel ? "#\(row.title)" : row.displayTitle) {
                            if row.unreadCount > 0 && !row.isMuted { RaftSticker(kind: .count(row.unreadCount)) }
                        }
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var pinnedRows: [HomeRow] {
        var seen = Set<String>()
        return extras.pinned.compactMap { ref -> HomeRow? in
            let row: HomeRow?
            switch ref.kind {
            case "channel": row = list.row(id: ref.id)
            case "agent", "human":
                row = list.directMessages.first { $0.peerId == ref.id }.flatMap { list.row(id: $0.id) }
            default:
                row = list.row(id: ref.id) ?? list.directMessages.first { $0.peerId == ref.id }.flatMap { list.row(id: $0.id) }
            }
            guard let row, seen.insert(row.id).inserted else { return nil }
            return row
        }
    }

    // MARK: Unread cards

    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder private var unreadCards: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                ForEach(unreadRows) { row in unreadCard(row, fixed: false) }
            }
            .padding(.horizontal, 16)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(unreadRows) { row in unreadCard(row, fixed: true) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    private func unreadCard(_ row: HomeRow, fixed: Bool) -> some View {
        NavigationLink(value: AppRoute.conversation(ref(for: row))) {
            UnreadCard(row: row, persona: row.kind == .directMessage ? persona(for: row) : nil, preview: extras.previews[row.id], selfNames: selfNames, currentUserId: workspace.currentUserId, fixed: fixed)
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu { rowMenu(row) }
        .accessibilityIdentifier("unread-card-\(row.title)")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Home has no visible title (§3-06); the plain title still names the back button.
        ToolbarItem(placement: .principal) {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        }
        ToolbarItem(placement: .topBarLeading) {
            // XIN 5310 / Colo 5311: no glass capsule — avatar, name and chevron sit on the bar.
            Button {
                showsSwitcher = true
            } label: {
                HStack(spacing: 0) {
                    ServerAvatar(name: server?.name ?? "R", side: 28, cornerRadius: 7)
                    Text(verbatim: server?.name ?? "")
                        .font(.custom(RaftFont.bold, size: 19, relativeTo: .headline))
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 10)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.raftTextSecondary)
                        .padding(.leading, 6)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDimButtonStyle())
            .accessibilityLabel(Text(L10n.f("ios_switch_server_a11y", "%1$@, switch server", server?.name ?? "")))
            .accessibilityIdentifier("server-switcher")
            #if DEBUG
            .task {
                guard PreviewGallery.screen == "06b" else { return }
                try? await Task.sleep(for: .milliseconds(600))
                showsSwitcher = true
            }
            #endif
            .popover(isPresented: $showsSwitcher, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                ServerSwitcher(isPresented: $showsSwitcher)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        HomeSearchToolbarItems(namespace: searchZoom, serverName: server?.name ?? "")
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(selection: Binding(
                    get: { extras.notificationLevel ?? .all },
                    set: { level in
                        Task {
                            await extras.setNotificationLevel(level)
                            if let error = extras.errorMessage {
                                model.showToast(error)
                                extras.errorMessage = nil
                            }
                        }
                    }
                )) {
                    Text(L10n.t("settings_notifications_mode_all", "All new messages")).tag(NotificationLevel.all)
                    Text(L10n.t("settings_notifications_mode_mentions", "Direct messages, mentions & followed threads")).tag(NotificationLevel.mentions)
                    Text(L10n.t("member_label_muted", "Muted")).tag(NotificationLevel.none)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: extras.notificationLevel == NotificationLevel.none ? "bell.slash" : "bell")
            }
            .accessibilityLabel(Text(L10n.t("settings_notifications_title", "Notifications")))
            .accessibilityIdentifier("notifications-menu")
        }
    }

    // MARK: Actions

    private func markAllRead() {
        let ids = unreadRows.filter { $0.priority != .quiet }.map(\.id)
        Task { await markRead(ids) }
    }

    private func markRead(_ ids: [String]) async {
        do {
            try await workspace.markRead(channelIds: ids)
        } catch {
            model.showToast(ErrorText.describe(error))
        }
    }
}

struct HomeLayout: Equatable {
    var unreadIds: [String]
}

// MARK: Pieces

struct HomeChip<Trailing: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Color.raftTextSecondary)
            Text(verbatim: title)
                .raftFont(.chipLabel)
                .foregroundStyle(Color.raftTextPrimary)
                .lineLimit(1)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .raftCardSurface(.chip, radius: 12)
        .accessibilityElement(children: .combine)
    }
}

struct ChannelRowView: View {
    let row: HomeRow

    var body: some View {
        HStack(spacing: 12) {
            ChannelTile(isPrivate: row.channelType == "private", isMuted: row.isMuted)
            HStack(spacing: 6) {
                Text(verbatim: row.displayTitle)
                    .raftFont(row.isMuted ? .rowTitleMedium : .rowTitle)
                    .foregroundStyle(row.isMuted ? Color.raftTextTertiary : Color.raftTextPrimary)
                    .lineLimit(1)
                if row.isMuted {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.raftTextTertiary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: HomeA11y.label(row)))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var trailing: some View {
        if row.isMuted && row.unreadCount > 0 && !row.hasMention {
            MutedCount(value: row.unreadCount)
        } else if row.unreadCount > 0 || row.hasMention || row.threadUnreadCount > 0 {
            UnreadStickers(unread: row.unreadCount, mention: row.hasMention || row.threadHasMention, threadUnread: row.threadUnreadCount, muted: row.isMuted)
        } else if let date = row.lastActivity {
            Text(verbatim: RaftFormat.listTime(date))
                .raftFont(.monoCaption)
                .foregroundStyle(Color.raftTextTertiary)
        }
    }
}

struct DMRowView: View {
    let row: HomeRow
    let persona: Persona
    var selfNames: Set<String> = []

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(persona: persona, size: .md, showsPresence: true, ringColor: .raftCard)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.displayTitle)
                        .raftFont(.rowTitle)
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = row.lastActivity {
                        Text(verbatim: RaftFormat.listTime(date))
                            .raftFont(.monoCaption)
                            .foregroundStyle(Color.raftTextTertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(verbatim: HomeA11y.dmPreview(row, selfNames: selfNames))
                        .raftFont(.preview)
                        .foregroundStyle(Color.raftTextTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    UnreadStickers(unread: row.unreadCount, mention: row.hasMention, threadUnread: row.threadUnreadCount, muted: row.isMuted)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: HomeA11y.label(row, preview: HomeA11y.dmPreview(row, selfNames: selfNames), presence: persona.presence)))
        .accessibilityAddTraits(.isButton)
    }
}

struct UnreadCard: View {
    let row: HomeRow
    let persona: Persona?
    let preview: HomeExtrasStore.UnreadPreview?
    var selfNames: Set<String>
    var currentUserId: String
    var fixed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                if let persona {
                    AvatarView(persona: persona, size: .sm, showsPresence: true, ringColor: .raftCard)
                } else {
                    ChannelTile(isPrivate: row.channelType == "private", isMuted: false)
                }
                Spacer(minLength: 4)
                UnreadStickers(unread: row.unreadCount, mention: row.hasMention || row.threadHasMention, threadUnread: row.threadUnreadCount, muted: false)
            }
            .frame(height: 27)
            .padding(.bottom, 8)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The tile already shows the "#" (Colo review: no prefix on card titles).
                Text(verbatim: row.displayTitle)
                    .raftFont(.author)
                    .foregroundStyle(Color.raftTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let date = row.lastActivity {
                    Text(verbatim: RaftFormat.listTime(date))
                        .raftFont(.monoSmall)
                        .foregroundStyle(Color.raftTextTertiary)
                        .fixedSize()
                }
            }
            previewText
                .lineLimit(3)
                .padding(.top, 3)
            if fixed { Spacer(minLength: 0) }
        }
        .padding(12)
        .frame(width: fixed ? 166 : nil, height: fixed ? 132 : nil, alignment: .topLeading)
        .frame(maxWidth: fixed ? nil : .infinity, alignment: .leading)
        .raftCardSurface(.unreadCard, radius: 16)
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: HomeA11y.label(row, preview: plainPreview)))
        .accessibilityAddTraits(.isButton)
    }

    private var plainPreview: String {
        if let threadTitle = preview?.threadTitle {
            return L10n.f("ios_thread_reply_preview", "%1$@ replied in “%2$@”", preview?.sender ?? "", PlainText.preview(threadTitle))
        }
        let text = PlainText.preview(preview?.text ?? (row.kind == .directMessage ? row.preview : nil))
        let sender = preview?.sender ?? row.previewSender
        if let sender, !sender.isEmpty, row.kind == .channel { return "\(sender): \(text)" }
        return text
    }

    @ViewBuilder private var previewText: some View {
        if let threadTitle = preview?.threadTitle {
            let format = L10n.t("ios_thread_reply_preview", "%1$@ replied in “%2$@”")
            let parts = format.components(separatedBy: "%1$@")
            let rest = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "%2$@", with: PlainText.preview(threadTitle))
            (Text(verbatim: parts.first ?? "")
                + Text(verbatim: preview?.sender ?? "").font(.custom(RaftFont.semibold, size: 13, relativeTo: .footnote)).foregroundStyle(Color.raftTextPrimary)
                + Text(verbatim: rest))
                .raftFont(.footnote)
                .foregroundStyle(Color.raftTextSecondary)
        } else {
            let text = PlainText.preview(preview?.text ?? (row.kind == .directMessage ? row.preview : nil))
            let sender = preview?.sender ?? row.previewSender
            let mine = sender.map { selfNames.contains($0) } ?? false
            let prefix: String? = mine ? L10n.t("activity_list_self_sender", "You") : (row.kind == .channel ? sender : nil)
            (prefix.map { Text(verbatim: "\($0): ").font(.custom(RaftFont.semibold, size: 13, relativeTo: .footnote)).foregroundStyle(Color.raftTextPrimary) } ?? Text(verbatim: ""))
                + MessageTextBuilder(content: text, mentions: [], currentUserId: currentUserId, channelNames: [], font: .footnote, color: .raftTextSecondary, pills: false).text
        }
    }
}

enum HomeA11y {
    static func dmPreview(_ row: HomeRow, selfNames: Set<String>) -> String {
        let text = PlainText.preview(row.preview)
        if let sender = row.previewSender, selfNames.contains(sender) {
            return "\(L10n.t("activity_list_self_sender", "You")): \(text)"
        }
        return text
    }

    static func label(_ row: HomeRow, preview: String? = nil, presence: Presence? = nil) -> String {
        var parts = [row.displayTitle]
        if row.peerType == "agent" {
            parts.append(L10n.t("member_label_agent", "Agent"))
            if let presence { parts.append(presence.label) }
        }
        if row.isMuted { parts.append(L10n.t("member_label_muted", "Muted")) }
        if row.unreadCount > 0 { parts.append(L10n.f("ios_unread_count_a11y", "%1$d unread", row.unreadCount)) }
        if row.hasMention || row.threadHasMention { parts.append(L10n.t("ios_mentions_you_a11y", "mentions you")) }
        if row.threadUnreadCount > 0 { parts.append(L10n.f("ios_thread_unread_a11y", "%1$d thread replies", row.threadUnreadCount)) }
        var label = parts.joined(separator: ", ")
        if let preview, !preview.isEmpty { label += ". \(preview)" }
        if let date = row.lastActivity { label += ". \(RaftFormat.listTime(date))" }
        return label
    }
}

// MARK: 07 Skeleton

struct HomeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([64, 120, 52], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.raftCard)
                        .frame(width: CGFloat(width) + 24, height: 40)
                        .overlay(SkeletonBlock(width: CGFloat(width), height: 12))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            SkeletonBlock(width: 70, height: 12).padding(.leading, 20).padding(.top, 26).padding(.bottom, 10)
            // The card row is wider than the screen; host it in an overlay so it
            // cannot widen (and re-centre) the whole skeleton.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .overlay(alignment: .leading) {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                SkeletonBlock(width: 27, height: 27)
                                SkeletonBlock(width: 90, height: 14)
                                SkeletonBlock(width: 130, height: 10)
                                SkeletonBlock(width: 110, height: 10)
                            }
                            .padding(12)
                            .frame(width: 166, height: 132, alignment: .topLeading)
                            .background(Color.raftCard, in: .rect(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .fixedSize()
                    .padding(.leading, 16)
                }
                .clipped()
            SkeletonBlock(width: 80, height: 12).padding(.leading, 20).padding(.top, 26).padding(.bottom, 10)
            RaftGroupCard {
                ForEach(Array([90, 70, 110, 84].enumerated()), id: \.offset) { index, width in
                    if index > 0 { RowDivider(inset: 53) }
                    HStack(spacing: 12) {
                        SkeletonBlock(width: 27, height: 27)
                        SkeletonBlock(width: CGFloat(width), height: 14)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                }
            }
            SkeletonBlock(width: 110, height: 12).padding(.leading, 20).padding(.top, 26).padding(.bottom, 10)
            RaftGroupCard {
                ForEach(Array([60, 90, 70, 80].enumerated()), id: \.offset) { index, width in
                    if index > 0 { RowDivider(inset: 61) }
                    HStack(spacing: 12) {
                        SkeletonBlock(width: 35, height: 35)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: CGFloat(width), height: 14)
                            SkeletonBlock(width: CGFloat(width + 90), height: 10)
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
        .accessibilityIdentifier("home-skeleton")
    }
}

/// The bare server switcher dims as a whole while pressed (Colo 5311).
private struct PressDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
