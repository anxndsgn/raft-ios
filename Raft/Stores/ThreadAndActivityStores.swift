import Foundation
import Observation

/// A thread: its parent message and the replies (a thread is a channel of type `thread`; replies
/// load and send like any conversation). A thread with no reply has no channel yet: it is created
/// (`POST channels/{parent}/threads`) by the first reply, never by opening.
@MainActor
@Observable
final class ThreadStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let parentChannelId: String
    let parentMessageId: String
    let title: String
    private(set) var phase: Phase = .idle
    private(set) var parent: Message?
    private(set) var threadChannelId: String?
    /// Nil until the thread exists.
    private(set) var replies: ConversationStore?
    private(set) var replyCount: Int?
    private(set) var isCreatingThread = false
    /// Replies sent before the thread exists, shown at once while it is created.
    private(set) var pendingBeforeThread: [PendingSend] = []
    @ObservationIgnored private var creating: Task<String?, Never>?
    /// This person follows the thread (nil until known).
    private(set) var isFollowing: Bool?
    var errorMessage: String?

    @ObservationIgnored private let api: RaftAPI
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let focusMessageId: String?
    /// Builds the replies store (the workspace registers it for live events).
    @ObservationIgnored private let makeReplies: @MainActor (_ threadChannelId: String, _ parentMessageId: String) -> ConversationStore?
    @ObservationIgnored var joiner: (any RealtimeChannelJoining)?
    @ObservationIgnored private var joinedChannelId: String?

    init(
        ref: ThreadRef,
        api: RaftAPI,
        preferences: AppPreferences,
        makeReplies: @escaping @MainActor (String, String) -> ConversationStore?
    ) {
        parentChannelId = ref.parentChannelId
        parentMessageId = ref.parentMessageId
        title = ref.title
        parent = ref.parent
        threadChannelId = ref.threadChannelId
        focusMessageId = ref.focusMessageId
        self.api = api
        self.preferences = preferences
        self.makeReplies = makeReplies
    }

    /// Loads the parent when not given, finds the thread channel, loads the newest replies and
    /// joins the thread's socket room (replies under a public parent are broadcast there).
    func start() async {
        guard phase != .loaded else { return }
        phase = .loading
        if parent == nil {
            do {
                let context = try await api.messageContext(messageId: parentMessageId, channelId: parentChannelId)
                parent = context.messages.first { $0.id == parentMessageId }
            } catch {
                phase = .failed(ErrorText.describe(error))
                return
            }
        }
        if threadChannelId == nil {
            threadChannelId = parent?.threadSummary?.threadChannelId
        }
        let summaries = try? await api.threadSummaries(channelId: parentChannelId, parentMessageIds: [parentMessageId])
        if let summary = summaries?[parentMessageId] {
            threadChannelId = threadChannelId ?? summary.threadChannelId
            replyCount = summary.replyCount
            isFollowing = summary.followed
        }
        if let threadChannelId, let store = attachReplies(threadChannelId) {
            await store.start(focusMessageId: focusMessageId)
            await join(threadChannelId)
        }
        phase = .loaded
    }

    func stop() async {
        replies?.isVisible = false
        if let joinedChannelId, let joiner {
            await joiner.leaveChannel(joinedChannelId)
        }
        joinedChannelId = nil
    }

    /// Follow / unfollow (`POST channels/threads/follow|unfollow`), optimistic.
    func setFollowing(_ follow: Bool) async {
        guard !preferences.readOnly else {
            errorMessage = StoreError.readOnly.errorDescription
            return
        }
        let previous = isFollowing
        isFollowing = follow
        do {
            try await api.setThreadFollow(parentMessageId: parentMessageId, follow: follow)
        } catch {
            isFollowing = previous
            errorMessage = ErrorText.describe(error)
        }
    }

    /// Sends a reply; the first one creates the thread.
    func sendReply(_ text: String, mentions: [MessageMention] = [], attachmentIds: [String] = [], attachmentNames: [String] = []) async {
        guard let randomId = enqueueReply(text, mentions: mentions, hasAttachments: !attachmentIds.isEmpty, attachmentNames: attachmentNames) else { return }
        await deliverReply(randomId, attachmentIds: attachmentIds)
    }

    /// The reply's pending row, synchronously (on the tap). Before the thread exists it is held
    /// here (`pendingBeforeThread`); once the thread is created it moves, same `randomId`, into
    /// the replies store, which matches the server's copy to it.
    @discardableResult
    func enqueueReply(_ text: String, mentions: [MessageMention] = [], hasAttachments: Bool = false, attachmentNames: [String] = []) -> String? {
        guard !preferences.readOnly else {
            errorMessage = StoreError.readOnly.errorDescription
            return nil
        }
        if let replies {
            return replies.enqueue(text, mentions: mentions, hasAttachments: hasAttachments, attachmentNames: attachmentNames)
        }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || hasAttachments else { return nil }
        guard content.count <= SendMessageBody.maxContentLength else {
            errorMessage = "That message is too long."
            return nil
        }
        let item = PendingSend(
            randomId: ConversationStore.makeRandomId(),
            channelId: parentChannelId,
            content: content,
            mentions: mentions,
            state: .sending,
            createdAt: Date(),
            attachmentNames: attachmentNames
        )
        pendingBeforeThread.append(item)
        return item.randomId
    }

    /// Creates the thread when needed, then sends the enqueued reply.
    func deliverReply(_ randomId: String, attachmentIds: [String]) async {
        if pendingBeforeThread.contains(where: { $0.randomId == randomId }) {
            let failure = await ensureThread()
            guard let index = pendingBeforeThread.firstIndex(where: { $0.randomId == randomId }) else { return }
            guard failure == nil, let replies else {
                // The row turns failed (tap to retry), as a failed send does.
                pendingBeforeThread[index].attachmentIds = attachmentIds
                pendingBeforeThread[index].state = .failed(failure ?? "")
                return
            }
            // Same turn: the row leaves this list and joins the replies store, no flicker.
            let item = pendingBeforeThread.remove(at: index)
            // `deliver` below drops it (with "Upload failed") if every file failed and there
            // is no text.
            replies.enqueue(
                item.content,
                mentions: item.mentions,
                hasAttachments: !item.attachmentNames.isEmpty || !attachmentIds.isEmpty,
                attachmentNames: item.attachmentNames,
                randomId: item.randomId,
                createdAt: item.createdAt
            )
        }
        guard let replies else { return }
        await replies.deliver(randomId, attachmentIds: attachmentIds)
        // Replying follows the thread on the server. A brand-new thread has no summary yet
        // (`nil`), so set it whenever it is not already on.
        if !replies.pending.contains(where: { $0.randomId == randomId }), isFollowing != true {
            isFollowing = true
        }
    }

    /// A first reply whose thread could not be created: try again (same `randomId`).
    func retryBeforeThread(_ randomId: String) async {
        guard !preferences.readOnly else {
            errorMessage = StoreError.readOnly.errorDescription
            return
        }
        guard let index = pendingBeforeThread.firstIndex(where: { $0.randomId == randomId }), case .failed = pendingBeforeThread[index].state else { return }
        pendingBeforeThread[index].state = .sending
        await deliverReply(randomId, attachmentIds: pendingBeforeThread[index].attachmentIds)
    }

    func discardBeforeThread(_ randomId: String) {
        pendingBeforeThread.removeAll { $0.randomId == randomId }
    }

    /// One `POST channels/{parent}/threads` however many replies wait for it. Nil when the
    /// thread exists, else why it could not be created.
    private func ensureThread() async -> String? {
        if replies != nil { return nil }
        if let creating { return await creating.value }
        let task = Task { @MainActor [weak self] () -> String? in
            guard let self else { return "" }
            isCreatingThread = true
            defer { isCreatingThread = false }
            do {
                let created = try await api.createThread(channelId: parentChannelId, parentMessageId: parentMessageId)
                threadChannelId = created.threadChannelId
                await attachReplies(created.threadChannelId)?.loadLatest()
                await join(created.threadChannelId)
                return replies != nil ? nil : ""
            } catch {
                return ErrorText.describe(error)
            }
        }
        creating = task
        let failure = await task.value
        creating = nil
        return failure
    }

    // MARK: Live

    /// `thread:updated` for this parent: the count, and the thread channel when another person's
    /// reply created it while this screen was open.
    func applyThreadUpdate(_ update: ThreadUpdate) {
        guard update.parentMessageId == parentMessageId else { return }
        replyCount = update.replyCount
        if replies == nil, let id = update.threadChannelId, let store = attachReplies(id) {
            threadChannelId = id
            Task { [weak self] in
                await store.loadLatest()
                await self?.join(id)
            }
        }
    }

    /// `message:updated` of the parent.
    func applyParentUpdate(_ message: Message) {
        guard message.id == parentMessageId else { return }
        parent = message
    }

    #if DEBUG
    func debugSeed(parent: Message, replies: ConversationStore?, following: Bool? = true) {
        self.parent = parent
        self.replies = replies
        isFollowing = following
        replyCount = replies?.messages.count
        threadChannelId = replies?.channelId
        phase = .loaded
    }
    #endif

    @discardableResult
    private func attachReplies(_ threadChannelId: String) -> ConversationStore? {
        if let replies, replies.channelId == threadChannelId { return replies }
        guard let store = makeReplies(threadChannelId, parentMessageId) else { return nil }
        replies = store
        return store
    }

    private func join(_ channelId: String) async {
        guard joinedChannelId != channelId, let joiner else { return }
        await joiner.joinChannel(channelId)
        joinedChannelId = channelId
    }
}

/// Activity: the server's Inbox rows (mentions, followed-thread replies, unread channels and
/// DMs), refreshed on `activity:changed` and live messages, read state applied in place.
@MainActor
@Observable
final class ActivityStore {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all
        case mentions
        case unread

        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var filter: Filter = .all
    private(set) var phase: Phase = .idle
    private(set) var items: [InboxItem] = []
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private(set) var totalUnreadCount: Int?
    var errorMessage: String?

    @ObservationIgnored let currentUserId: String
    @ObservationIgnored private let api: RaftAPI
    @ObservationIgnored var pageSize = 30
    @ObservationIgnored let refreshCoalescer = Coalescer(delay: .seconds(3))
    @ObservationIgnored private var loadGeneration = 0

    init(api: RaftAPI, currentUserId: String) {
        self.api = api
        self.currentUserId = currentUserId
    }

    /// Rows with something unread (the tab badge).
    var unreadRowCount: Int { items.filter { $0.unreadCount > 0 }.count }

    func setFilter(_ value: Filter) async {
        guard value != filter else { return }
        filter = value
        items = []
        hasMore = false
        await load()
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if items.isEmpty { phase = .loading }
        do {
            let page = try await api.inbox(filter: filter.rawValue, limit: pageSize, offset: 0)
            guard generation == loadGeneration else { return }
            items = page.items
            hasMore = page.hasMore
            totalUnreadCount = page.totalUnreadCount
            phase = .loaded
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            if items.isEmpty {
                phase = .failed(ErrorText.describe(error))
            } else {
                errorMessage = ErrorText.describe(error)
            }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, phase == .loaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        do {
            let page = try await api.inbox(filter: filter.rawValue, limit: pageSize, offset: items.count)
            guard generation == loadGeneration else { return }
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            hasMore = page.hasMore
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }

    /// Re-reads the first page soon (coalesced); only once Activity has been loaded.
    func scheduleRefresh() {
        guard phase == .loaded else { return }
        refreshCoalescer.schedule { [weak self] in await self?.load() }
    }

    /// A live message from someone else changes some row (its unread, a mention, a reply).
    func noteMessage(_ message: Message) {
        guard !(message.senderType == "user" && message.senderId == currentUserId) else { return }
        scheduleRefresh()
    }

    /// `read_state:updated`: rows about that scope take the new count.
    func applyReadState(_ update: ReadStateUpdate) {
        for index in items.indices where items[index].scopeChannelId == update.scopeId {
            if let incoming = update.readStateVersion, let held = items[index].readStateVersion, incoming <= held { continue }
            items[index].readStateVersion = update.readStateVersion ?? items[index].readStateVersion
            let count = update.unreadCount ?? (update.markedUnread == true ? max(1, items[index].unreadCount) : 0)
            items[index].unreadCount = count
            if count == 0 { items[index].hasMention = false }
        }
    }

    #if DEBUG
    func debugSeed(phase: Phase, items: [InboxItem], filter: Filter = .all) {
        self.phase = phase
        self.items = items
        self.filter = filter
    }
    #endif

    /// Where a row leads: the conversation at its first mention / unread / latest message, or the
    /// thread. Object rows (apps) and task conversations are not part of v1.
    func route(for item: InboxItem) -> AppRoute? {
        let focus = item.firstMentionMessageId ?? item.firstUnreadMessageId ?? item.latestMessageId
        switch item.kind {
        case "channel", "dm":
            guard let channelId = item.channelId else { return nil }
            return .conversation(ConversationRef(
                channelId: channelId,
                title: item.channelName ?? "",
                kind: item.kind == "dm" ? .directMessage : .channel,
                focusMessageId: focus
            ))
        case "thread":
            guard let parentChannelId = item.parentChannelId, let parentMessageId = item.parentMessageId else { return nil }
            return .thread(ThreadRef(
                parentChannelId: parentChannelId,
                parentMessageId: parentMessageId,
                threadChannelId: item.threadChannelId,
                title: item.parentChannelName ?? "",
                focusMessageId: focus
            ))
        default:
            return nil
        }
    }
}
