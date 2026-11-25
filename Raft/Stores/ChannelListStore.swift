import Foundation
import Observation

/// A row of the Home list: a channel or a direct message, with its unread state.
struct HomeRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case channel
        case directMessage
    }

    /// Home ordering: mentions first, then unread, then everything else.
    enum Priority: Int, Comparable, Sendable {
        case mention = 0
        case unread = 1
        case quiet = 2

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var kind: Kind
    var title: String
    /// `channel`, `private`, `joint`, `dm`, ... as the server sends it.
    var channelType: String
    /// DMs: `user` or `agent`.
    var peerType: String?
    var avatarURL: String?
    /// DMs: the last message's text and sender.
    var preview: String?
    var previewSender: String?
    var unreadCount: Int
    var hasMention: Bool
    /// Unread replies in followed threads under this conversation.
    var threadUnreadCount: Int
    var threadHasMention: Bool
    /// Activity muted: its unread alone does not lift it to the top.
    var isMuted: Bool
    var lastActivity: Date?
    var maxReadSeq: Int64?
    /// A DM with yourself.
    var isSelf = false

    /// What the row shows: a DM with yourself says so ("XIN (you)"). `title` stays the plain
    /// name (order, identifiers, the avatar's initials).
    var displayTitle: String { isSelf ? L10n.withYouSuffix(title) : title }

    var priority: Priority {
        if hasMention || threadHasMention { return .mention }
        if (unreadCount > 0 && !isMuted) || threadUnreadCount > 0 { return .unread }
        return .quiet
    }

    var conversationKind: ConversationKind { kind == .channel ? .channel : .directMessage }

    /// Mentions, then unread, then the most recent activity, then the title.
    static func homeOrder(_ lhs: HomeRow, _ rhs: HomeRow) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        switch (lhs.lastActivity, rhs.lastActivity) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// Unread state of one conversation scope (channel, DM or thread).
struct ScopeUnread: Hashable, Sendable {
    var unreadCount: Int = 0
    var hasMention = false
    var readStateVersion: Int64?
    var maxReadSeq: Int64?
}

/// Home: the selected server's channels and DMs with unread and mention counts, kept fresh by
/// socket events (`message:new`, `read_state:*`, `channel:updated`, `dm:new`) between REST reads
/// (`channels`, `channels/dm`, `channels/unread?summary=1`).
@MainActor
@Observable
final class ChannelListStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var channels: [Channel] = []
    private(set) var directMessages: [DirectMessageChannel] = []
    private(set) var unread: [String: ScopeUnread] = [:]
    private(set) var threadUnread: [String: UnreadSummary.ThreadUnread] = [:]
    private(set) var lastLoadedAt: Date?
    /// The unread summary failed or came back stale; counts may lag.
    private(set) var unreadIsStale = false

    @ObservationIgnored let serverId: String
    @ObservationIgnored let currentUserId: String
    @ObservationIgnored private let api: RaftAPI
    @ObservationIgnored let unreadRefresh = Coalescer(delay: .seconds(2))
    @ObservationIgnored let dmRefresh = Coalescer(delay: .milliseconds(300))
    @ObservationIgnored private var refreshing = false

    init(api: RaftAPI, serverId: String, currentUserId: String) {
        self.api = api
        self.serverId = serverId
        self.currentUserId = currentUserId
    }

    // MARK: Rows

    /// Channels and DMs together, mentions first, then unread, then recent.
    var rows: [HomeRow] { (channelRows + directMessageRows).sorted(by: HomeRow.homeOrder) }

    /// Joined, unarchived channels in Home order.
    var channelRows: [HomeRow] {
        channels
            .filter { $0.joined && !$0.isArchived && $0.type != "dm" && $0.type != "thread" }
            .map(row(for:))
            .sorted(by: HomeRow.homeOrder)
    }

    var directMessageRows: [HomeRow] {
        directMessages.map(row(for:)).sorted(by: HomeRow.homeOrder)
    }

    /// Conversations with a mention (channel or its threads).
    var mentionCount: Int { (channelRows + directMessageRows).filter { $0.priority == .mention }.count }
    /// Conversations that need attention (mention or unread).
    var attentionCount: Int { (channelRows + directMessageRows).filter { $0.priority != .quiet }.count }

    func row(id: String) -> HomeRow? {
        if let channel = channels.first(where: { $0.id == id }) { return row(for: channel) }
        if let dm = directMessages.first(where: { $0.id == id }) { return row(for: dm) }
        return nil
    }

    func isDirectMessage(_ id: String) -> Bool { directMessages.contains { $0.id == id } }

    private func row(for channel: Channel) -> HomeRow {
        let scope = unread[channel.id] ?? ScopeUnread()
        let threads = threadUnread[channel.id]
        return HomeRow(
            id: channel.id,
            kind: .channel,
            title: channel.name,
            channelType: channel.type,
            peerType: nil,
            avatarURL: nil,
            preview: nil,
            previewSender: nil,
            unreadCount: scope.unreadCount,
            hasMention: scope.hasMention,
            threadUnreadCount: threads?.count ?? 0,
            threadHasMention: threads?.hasMention ?? false,
            isMuted: channel.activityMuted,
            lastActivity: RaftDate.parse(channel.lastMessageAt),
            maxReadSeq: scope.maxReadSeq ?? channel.maxReadSeq
        )
    }

    private func row(for dm: DirectMessageChannel) -> HomeRow {
        let scope = unread[dm.id] ?? ScopeUnread()
        let threads = threadUnread[dm.id]
        return HomeRow(
            id: dm.id,
            kind: .directMessage,
            title: dm.peerVisibleName,
            channelType: dm.type,
            peerType: dm.peerType,
            avatarURL: dm.peerAvatarUrl,
            preview: dm.lastMessagePreview,
            previewSender: dm.lastMessageSenderName,
            unreadCount: scope.unreadCount,
            hasMention: scope.hasMention,
            threadUnreadCount: threads?.count ?? 0,
            threadHasMention: threads?.hasMention ?? false,
            isMuted: dm.activityMuted,
            lastActivity: RaftDate.parse(dm.lastMessageAt),
            maxReadSeq: scope.maxReadSeq ?? dm.maxReadSeq,
            isSelf: dm.isSelf(currentUserId: currentUserId)
        )
    }

    // MARK: Loading

    /// Channels, DMs and the unread summary in parallel. The lists are required; a failed unread
    /// read leaves the previous counts (marked stale).
    func load() async {
        if channels.isEmpty && directMessages.isEmpty { phase = .loading }
        let api = self.api
        async let channelsResult = captureResult { try await api.channels() }
        async let dmsResult = captureResult { try await api.directMessages() }
        async let unreadResult = captureResult { try await api.unreadSummary() }
        let (loadedChannels, loadedDMs, loadedUnread) = await (channelsResult, dmsResult, unreadResult)

        switch (loadedChannels, loadedDMs) {
        case (.success(let channels), .success(let dms)):
            self.channels = channels
            self.directMessages = dms.dms
            seedReadVersions()
            phase = .loaded
            lastLoadedAt = Date()
        case (.failure(let error), _), (_, .failure(let error)):
            if channels.isEmpty && directMessages.isEmpty {
                phase = .failed(ErrorText.describe(error))
            }
        }
        switch loadedUnread {
        case .success(let summary): applySummary(summary)
        case .failure: unreadIsStale = true
        }
    }

    /// `load()` unless one is running (pull to refresh, reconnect).
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await load()
    }

    func refreshUnread() async {
        do {
            applySummary(try await api.unreadSummary())
        } catch {
            unreadIsStale = true
        }
    }

    func scheduleUnreadRefresh() {
        unreadRefresh.schedule { [weak self] in await self?.refreshUnread() }
    }

    func refreshDirectMessages() async {
        guard let list = try? await api.directMessages() else { return }
        directMessages = list.dms
        seedReadVersions()
    }

    func scheduleDirectMessageRefresh() {
        dmRefresh.schedule { [weak self] in await self?.refreshDirectMessages() }
    }

    private func applySummary(_ summary: UnreadSummary) {
        var next: [String: ScopeUnread] = [:]
        for (scopeId, entry) in summary.channels {
            var scope = ScopeUnread(unreadCount: entry.unreadCount, hasMention: entry.hasMention)
            scope.readStateVersion = entry.readState?["readStateVersion"]?.int64Value ?? unread[scopeId]?.readStateVersion
            scope.maxReadSeq = entry.readState?["maxReadSeq"]?.int64Value ?? unread[scopeId]?.maxReadSeq
            next[scopeId] = scope
        }
        // Scopes the summary leaves out are read.
        for (scopeId, scope) in unread where next[scopeId] == nil {
            next[scopeId] = ScopeUnread(readStateVersion: scope.readStateVersion, maxReadSeq: scope.maxReadSeq)
        }
        unread = next
        threadUnread = summary.threadUnread
        unreadIsStale = summary.stale
    }

    private func seedReadVersions() {
        for channel in channels {
            seed(channel.id, version: channel.readStateVersion, maxReadSeq: channel.maxReadSeq)
        }
        for dm in directMessages {
            seed(dm.id, version: dm.readStateVersion, maxReadSeq: dm.maxReadSeq)
        }
    }

    private func seed(_ id: String, version: Int64?, maxReadSeq: Int64?) {
        var scope = unread[id] ?? ScopeUnread()
        if let version, version > (scope.readStateVersion ?? -1) {
            scope.readStateVersion = version
            scope.maxReadSeq = maxReadSeq
        } else if scope.maxReadSeq == nil {
            scope.maxReadSeq = maxReadSeq
        }
        unread[id] = scope
    }

    #if DEBUG
    /// Preview gallery: a list state without a server round trip.
    func debugSeed(phase: Phase, channels: [Channel] = [], directMessages: [DirectMessageChannel] = [], unread: [String: ScopeUnread] = [:], threadUnread: [String: UnreadSummary.ThreadUnread] = [:]) {
        self.phase = phase
        self.channels = channels
        self.directMessages = directMessages
        self.unread = unread
        self.threadUnread = threadUnread
        lastLoadedAt = Date()
    }
    #endif

    // MARK: Live updates

    /// `message:new` (or a resumed message). `viewing`: the conversation is on screen, so its
    /// unread does not grow.
    func noteMessage(_ message: Message, viewing: Bool) {
        guard let channelId = message.channelId else { return }
        if message.isThreadReply {
            // Thread unread is per followed thread; the summary knows which ones count.
            scheduleUnreadRefresh()
            return
        }
        let mine = message.senderType == "user" && message.senderId == currentUserId
        if let index = channels.firstIndex(where: { $0.id == channelId }) {
            if let createdAt = message.createdAt { channels[index].lastMessageAt = createdAt }
        } else if let index = directMessages.firstIndex(where: { $0.id == channelId }) {
            if let createdAt = message.createdAt { directMessages[index].lastMessageAt = createdAt }
            directMessages[index].lastMessagePreview = message.content
            directMessages[index].lastMessageSenderName = message.senderName
        } else {
            // A conversation the list does not hold yet: a new DM, or a channel just joined.
            scheduleDirectMessageRefresh()
            return
        }
        guard !mine, !message.isDeleted, message.messageType != "system" else { return }
        var scope = unread[channelId] ?? ScopeUnread()
        if let seq = message.seq, let read = scope.maxReadSeq, seq <= read { return }
        if viewing { return }
        scope.unreadCount += 1
        if message.mentionsUser(currentUserId) { scope.hasMention = true }
        unread[channelId] = scope
    }

    /// `read_state:updated` / `_bulk`: version-gated (an older version than the one held is
    /// dropped, as the web's `consumeReadStateUpdate`).
    func applyReadState(_ update: ReadStateUpdate) {
        if let serverId = update.serverId, serverId != self.serverId { return }
        var scope = unread[update.scopeId] ?? ScopeUnread()
        if let incoming = update.readStateVersion, let held = scope.readStateVersion, incoming <= held { return }
        scope.readStateVersion = update.readStateVersion ?? scope.readStateVersion
        scope.maxReadSeq = update.maxReadSeq ?? scope.maxReadSeq
        let known = channels.contains { $0.id == update.scopeId } || directMessages.contains { $0.id == update.scopeId }
        if let count = update.unreadCount {
            scope.unreadCount = count
            if count == 0 { scope.hasMention = false }
        } else if update.markedUnread == true {
            scope.unreadCount = max(scope.unreadCount, 1)
        } else {
            scope.unreadCount = 0
            scope.hasMention = false
        }
        unread[update.scopeId] = scope
        if !known || update.unreadCount == nil {
            // A thread scope (counted per parent), or a count the event did not carry.
            scheduleUnreadRefresh()
        }
    }

    /// The conversation was read here (after `POST channels/{id}/read`).
    func noteLocallyRead(channelId: String, seq: Int64) {
        var scope = unread[channelId] ?? ScopeUnread()
        scope.unreadCount = 0
        scope.hasMention = false
        scope.maxReadSeq = max(scope.maxReadSeq ?? 0, seq)
        unread[channelId] = scope
    }

    /// The conversation was read entirely here (after `POST channels/{id}/read-all`).
    func noteLocallyReadAll(channelId: String) {
        var scope = unread[channelId] ?? ScopeUnread()
        scope.unreadCount = 0
        scope.hasMention = false
        unread[channelId] = scope
        threadUnread[channelId] = nil
    }

    /// `channel:updated`: `{ channel }` with the full row (upserted), or an id only (re-read it).
    /// Rows of another server (the event can reach the user's room) are ignored.
    func applyChannelUpdate(channelId: String?, raw: JSONValue) async {
        if let value = raw["channel"], let channel = try? value.decode(Channel.self) {
            upsert(channel)
            return
        }
        if let channelId {
            if let channel = try? await api.channel(id: channelId) { upsert(channel) }
            return
        }
        await refresh()
    }

    func upsert(_ channel: Channel) {
        if let serverId = channel.serverId, serverId != self.serverId { return }
        if channel.type == "dm" {
            scheduleDirectMessageRefresh()
            return
        }
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index] = channel
        } else {
            channels.append(channel)
        }
        seed(channel.id, version: channel.readStateVersion, maxReadSeq: channel.maxReadSeq)
    }
}

extension DirectMessageChannel {
    /// A DM with yourself: the server lists it as a user DM whose peer is you.
    func isSelf(currentUserId: String) -> Bool {
        peerType == "user" && !currentUserId.isEmpty && peerId == currentUserId
    }

    /// The DM's name wherever it shows: the peer's, with "(you)" for a DM with yourself.
    func displayTitle(currentUserId: String) -> String {
        isSelf(currentUserId: currentUserId) ? L10n.withYouSuffix(peerVisibleName) : peerVisibleName
    }
}
