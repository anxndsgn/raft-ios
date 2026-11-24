import SwiftUI

// MARK: 17 / 18 Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @AppStorage("raft.activity.filter") private var storedFilter = ActivityStore.Filter.all.rawValue
    @State private var showsSpinner = false

    private var store: ActivityStore { workspace.activity }

    /// The segmented control's order (§3-17): All / Unread / Mentions.
    static let filters: [ActivityStore.Filter] = [.all, .unread, .mentions]

    private var hasUnread: Bool { store.items.contains { $0.unreadCount > 0 } }

    var body: some View {
        List {
            filterPicker
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.raftCanvas)
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.raftCanvas.ignoresSafeArea())
        .environment(\.defaultMinListRowHeight, 1)
        .raftNavigationTitle(L10n.t("tab_activity", "Activity"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await markAllRead() }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(!hasUnread)
                .accessibilityLabel(Text(L10n.t("inbox_action_mark_all_read", "Mark all read")))
                .accessibilityIdentifier("activity-mark-all-read")
            }
        }
        .refreshable { await store.load() }
        .task {
            let filter = ActivityStore.Filter(rawValue: storedFilter) ?? .all
            if filter != store.filter {
                await store.setFilter(filter)
            } else if store.phase == .idle {
                await store.load()
            }
        }
        .task(id: store.phase == .loading) {
            showsSpinner = false
            guard store.phase == .loading else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsSpinner = true }
        }
        .onChange(of: store.errorMessage) { _, message in
            guard let message else { return }
            model.showToast(message)
            store.errorMessage = nil
        }
    }

    private var filterPicker: some View {
        Picker(selection: Binding(
            get: { store.filter },
            set: { value in
                storedFilter = value.rawValue
                Task { await store.setFilter(value) }
            }
        )) {
            ForEach(Self.filters) { filter in
                Text(Self.title(filter)).tag(filter)
            }
        } label: {
            Text(L10n.t("tab_activity", "Activity"))
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("activity-filter")
    }

    static func title(_ filter: ActivityStore.Filter) -> String {
        switch filter {
        case .all: L10n.t("activity_filter_all", "All")
        case .unread: L10n.t("activity_filter_unread", "Unread")
        case .mentions: L10n.t("activity_filter_mentions", "Mentions")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle, .loading:
            if showsSpinner {
                ProgressView()
                    .tint(.raftTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                    .plainRow()
            }
        case .failed:
            LoadErrorView(title: L10n.t("inbox_error_load_activity", "Could not load activity"), top: 72) {
                Task { await store.load() }
            }
            .plainRow()
        case .loaded:
            if store.items.isEmpty {
                EmptyStateView(title: L10n.t("ios_activity_empty_title", "You’re all caught up"), detail: emptyDetail, top: 72) {
                    AllReadSticker()
                }
                .plainRow()
                .transition(.opacity)
            } else {
                ForEach(groups, id: \.day) { group in
                    Text(verbatim: group.title)
                        .raftFont(.monoCaption)
                        .foregroundStyle(Color.raftTextTertiary)
                        .accessibilityAddTraits(.isHeader)
                        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                        .plainRow(insets: false)
                    ForEach(group.items) { item in
                        row(item)
                    }
                }
                if store.hasMore {
                    ProgressView()
                        .tint(.raftTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .plainRow()
                        .onAppear { Task { await store.loadMore() } }
                }
            }
        }
    }

    private var emptyDetail: String {
        switch store.filter {
        case .all: L10n.t("inbox_empty_all_detail", "Channels, DMs, and followed threads stay here until they are done.")
        case .unread: L10n.t("inbox_empty_unread_detail", "Channels, DMs, and followed threads stay here until they are done.")
        case .mentions: L10n.t("inbox_empty_mentions_detail", "Channels, DMs, and threads where someone @mentions you will appear here.")
        }
    }

    private struct DayGroup {
        var day: Date
        var title: String
        var items: [InboxItem]
    }

    private var groups: [DayGroup] {
        var result: [DayGroup] = []
        let calendar = Calendar.current
        for item in store.items {
            let date = RaftDate.parse(item.activityAt) ?? .distantPast
            let day = calendar.startOfDay(for: date)
            if let last = result.indices.last, result[last].day == day {
                result[last].items.append(item)
            } else {
                result.append(DayGroup(day: day, title: date == .distantPast ? "" : RaftFormat.day(date), items: [item]))
            }
        }
        return result
    }

    private func row(_ item: InboxItem) -> some View {
        let unread = item.unreadCount > 0
        return Button {
            if let route = store.route(for: item) { model.push(route) }
        } label: {
            ActivityRow(item: item, persona: persona(for: item), currentUserId: workspace.currentUserId, channelNames: channelNames)
        }
        .buttonStyle(RowButtonStyle())
        .listRowInsets(EdgeInsets())
        .plainRow(insets: false)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await setRead(item, read: unread) }
            } label: {
                if unread {
                    Label(L10n.t("ios_mark_as_read", "Mark as read"), systemImage: "checkmark.circle")
                } else {
                    Label(L10n.t("activity_swipe_layer_unread", "Unread"), systemImage: "circle.fill")
                }
            }
            .tint(Color(hex: 0x2F7FD8))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await mute(item) }
            } label: {
                Label(L10n.t("activity_action_mute_activity", "Mute Activity"), systemImage: "bell.slash")
            }
            .tint(Color(hex: 0x6E6A66))
        }
        .accessibilityIdentifier("activity-row-\(item.id)")
    }

    private var channelNames: Set<String> {
        Set(workspace.channelList.channels.map { $0.name.lowercased() })
    }

    private func persona(for item: InboxItem) -> Persona {
        let type = item.senderType == "agent" ? "agent" : "user"
        return workspace.directory.persona(type: type, id: item.senderId ?? item.id, name: item.senderName ?? item.title)
    }

    // MARK: Actions

    private func markAllRead() async {
        do {
            try await workspace.markAllActivityRead()
        } catch {
            model.showToast(ErrorText.describe(error))
        }
    }

    private func setRead(_ item: InboxItem, read: Bool) async {
        do {
            try await workspace.setActivityRow(item, read: read)
        } catch {
            model.showToast(ErrorText.describe(error))
        }
    }

    private func mute(_ item: InboxItem) async {
        do {
            try await workspace.muteActivity(item)
        } catch {
            model.showToast(ErrorText.describe(error))
        }
    }
}

extension View {
    /// A `List(.plain)` row drawn by the app: canvas background, no separator.
    func plainRow(insets: Bool = true) -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.raftCanvas)
            .modifier(OptionalInsets(apply: insets))
    }
}

private struct OptionalInsets: ViewModifier {
    let apply: Bool
    func body(content: Content) -> some View {
        if apply {
            content.listRowInsets(EdgeInsets())
        } else {
            content
        }
    }
}

// MARK: Rows

/// The type badge on an Activity row's avatar.
enum ActivityBadge {
    case mention
    case thread
    case directMessage
}

/// The Activity row layout (§3-17), shared with Saved.
struct ActivityRowLayout<Title: View>: View {
    let persona: Persona
    var badge: ActivityBadge?
    var unread: Bool
    let time: String?
    let location: String
    let preview: Text
    @ViewBuilder let title: () -> Title

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(persona: persona, size: .md)
                .overlay(alignment: .bottomTrailing) {
                    if let badge { badgeView(badge).offset(x: 6, y: 6) }
                }
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title()
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let time {
                        Text(verbatim: time)
                            .raftFont(.monoCaption)
                            .foregroundStyle(Color.raftTextTertiary)
                            .fixedSize()
                    }
                }
                if !location.isEmpty {
                    Text(verbatim: location)
                        .raftFont(.footnoteMedium)
                        .foregroundStyle(Color.raftTextTertiary)
                        .lineLimit(1)
                }
                preview
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if unread {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.raftPink)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.raftInk, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                    .dieCut(radius: 2)
                    .offset(x: 6, y: 24)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func badgeView(_ badge: ActivityBadge) -> some View {
        let (fill, symbol): (Color, String) = switch badge {
        case .mention: (.raftYellow, "at")
        case .thread: (.raftCyanSoft, "bubble.left.and.bubble.right")
        case .directMessage: (.raftPink, "text.bubble.fill")
        }
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return shape.fill(fill)
            .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: badge == .thread ? 8 : 10, weight: .bold))
                    .foregroundStyle(Color.raftInk)
            }
            .frame(width: 19, height: 19)
            .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(Color.raftCanvas).padding(-1.5))
            .accessibilityHidden(true)
    }
}

struct ActivityRow: View {
    let item: InboxItem
    let persona: Persona
    let currentUserId: String
    var channelNames: Set<String> = []

    private var unread: Bool { item.unreadCount > 0 }

    private var badge: ActivityBadge? {
        if item.hasMention { return .mention }
        if item.isSubConversation { return .thread }
        if item.kind == "dm" { return .directMessage }
        return nil
    }

    private var titleFormat: String {
        if item.hasMention { return L10n.t("push_preview_sender_only_mention", "%1$@ mentioned you") }
        if item.isSubConversation { return L10n.t("ios_activity_replied_thread", "%1$@ replied to a thread") }
        if item.kind == "dm" { return L10n.t("ios_activity_sent_message", "%1$@ sent you a message") }
        return L10n.t("ios_activity_posted", "%1$@ posted a message")
    }

    private var name: String {
        let value = persona.name
        return value == "?" ? (item.senderName ?? item.title) : value
    }

    private var location: String {
        let dm = L10n.t("thread_direct_message_title", "Direct message")
        if item.isSubConversation {
            let parent = item.parentChannelType == "dm" ? dm : "#\(item.parentChannelName ?? "")"
            let root = PlainText.preview(item.parentMessagePreview)
            return root.isEmpty ? parent : "\(parent) · \(root)"
        }
        if item.kind == "dm" { return dm }
        return "#\(item.channelName ?? "")"
    }

    private var date: Date? { RaftDate.parse(item.activityAt) }

    var body: some View {
        ActivityRowLayout(
            persona: persona,
            badge: badge,
            unread: unread,
            time: date.map { RaftFormat.relative($0) },
            location: location,
            preview: MessageTextBuilder(
                content: PlainText.preview(item.preview),
                mentions: [],
                currentUserId: currentUserId,
                channelNames: channelNames,
                font: .preview,
                color: unread ? .raftTextPrimary : .raftTextSecondary
            ).text
        ) {
            Text.emphasized(
                titleFormat,
                name,
                base: .activityTitle,
                strongFont: unread ? RaftFont.bold : RaftFont.semibold,
                strongColor: unread ? .raftTextPrimary : .raftTextSecondary
            )
            .foregroundStyle(unread ? Color.raftTextPrimary : Color.raftTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel))
        .accessibilityAddTraits(.isButton)
    }

    private var a11yLabel: String {
        var parts: [String] = []
        if unread { parts.append(L10n.t("activity_filter_unread", "Unread")) }
        parts.append(titleFormat.replacingOccurrences(of: "%1$@", with: name) + ", " + location)
        let preview = PlainText.preview(item.preview)
        if !preview.isEmpty { parts.append(preview) }
        if let date { parts.append(RaftFormat.spoken(date)) }
        return parts.joined(separator: ". ")
    }
}

// MARK: Saved (§10.2: Activity's row style)

struct SavedView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace

    private var extras: HomeExtrasStore { workspace.homeExtras }

    var body: some View {
        List {
            switch extras.savedPhase {
            case .idle, .loading:
                ProgressView()
                    .tint(.raftTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                    .plainRow()
            case .failed:
                LoadErrorView(title: L10n.t("ios_saved_error_load", "Could not load saved messages"), top: 72) {
                    Task { await extras.loadSaved() }
                }
                .plainRow()
            case .loaded:
                if extras.saved.isEmpty {
                    EmptyStateView(title: L10n.t("saved_empty_title", "No saved messages yet"), detail: L10n.t("inbox_empty_saved_detail", "Save a message and its thread shows up here."), top: 72) {
                        IllustrationSticker(systemImage: "bookmark", color: .raftYellow, side: 72, symbolSize: 30, shadow: 4)
                    }
                    .plainRow()
                } else {
                    Color.clear.frame(height: 6).plainRow()
                    ForEach(extras.saved) { entry in
                        Button {
                            model.push(route(for: entry))
                        } label: {
                            SavedRow(entry: entry, persona: workspace.directory.persona(type: entry.senderType, id: entry.senderId, name: entry.senderName, avatarURL: entry.senderAvatarUrl), currentUserId: workspace.currentUserId)
                        }
                        .buttonStyle(RowButtonStyle())
                        .plainRow()
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.raftCanvas.ignoresSafeArea())
        .environment(\.defaultMinListRowHeight, 1)
        .raftNavigationTitle(L10n.t("home_nav_saved", "Saved"))
        .refreshable { await extras.loadSaved() }
        .task { await extras.loadSaved() }
    }

    private func route(for entry: SavedEntry) -> AppRoute {
        if let parentId = entry.parentMessageId, let parentChannel = entry.parentChannelId {
            return .thread(ThreadRef(
                parentChannelId: parentChannel,
                parentMessageId: parentId,
                threadChannelId: entry.channelId,
                title: entry.parentChannelName ?? "",
                focusMessageId: entry.messageId
            ))
        }
        return .conversation(ConversationRef(
            channelId: entry.channelId,
            title: entry.channelName ?? "",
            kind: entry.channelType == "dm" ? .directMessage : .channel,
            focusMessageId: entry.messageId
        ))
    }
}

struct SavedRow: View {
    let entry: SavedEntry
    let persona: Persona
    let currentUserId: String

    private var location: String {
        if entry.channelType == "dm" { return L10n.t("thread_direct_message_title", "Direct message") }
        if entry.parentMessageId != nil {
            return "#\(entry.parentChannelName ?? entry.channelName ?? "") · \(L10n.t("thread_reply_title", "Thread"))"
        }
        return "#\(entry.channelName ?? "")"
    }

    var body: some View {
        let date = RaftDate.parse(entry.createdAt)
        ActivityRowLayout(
            persona: persona,
            unread: false,
            time: date.map { RaftFormat.listTime($0) },
            location: location,
            preview: MessageTextBuilder(content: PlainText.preview(entry.content), mentions: [], currentUserId: currentUserId, channelNames: [], font: .preview, color: .raftTextPrimary).text
        ) {
            Text(verbatim: persona.name)
                .font(.custom(RaftFont.bold, size: 15, relativeTo: .subheadline))
                .foregroundStyle(Color.raftTextPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(persona.name), \(location). \(PlainText.preview(entry.content))"))
        .accessibilityAddTraits(.isButton)
    }
}
