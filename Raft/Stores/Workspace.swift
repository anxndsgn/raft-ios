import Foundation
import Observation

/// Joins and leaves per-channel socket rooms (`join:channel` / `leave:channel`).
protocol RealtimeChannelJoining: AnyObject, Sendable {
    func joinChannel(_ channelId: String) async
    func leaveChannel(_ channelId: String) async
}

/// The realtime connection as the workspace uses it (the real `RealtimeClient`, or a fake in tests).
protocol RealtimeSource: RealtimeChannelJoining {
    func events() async -> AsyncStream<RealtimeEvent>
    func statuses() async -> AsyncStream<RealtimeStatus>
    func start() async
    func stop(reason: String) async
    func reconnectNow() async
}

extension RealtimeClient: RealtimeSource {}

/// One signed-in person on one server: the socket, the Home list, Activity, and the open
/// conversations and threads. Every socket event is routed from here to the stores that hold
/// what it changes. Built again when the server or the account changes.
@MainActor
@Observable
final class Workspace {
    let serverId: String
    let currentUserId: String
    let channelList: ChannelListStore
    let activity: ActivityStore
    /// People and agents (loaded by the app, not by `start()`).
    let directory: DirectoryStore
    let homeExtras: HomeExtrasStore
    @ObservationIgnored let attachments: AttachmentStore
    private(set) var connection: RealtimeStatus = .idle {
        didSet {
            if case .connected = connection { lastConnectedAt = Date() }
        }
    }
    /// The last time the socket was connected (the offline banner's "Updated").
    private(set) var lastConnectedAt: Date?
    /// `rooms:join_failed` until the next `rooms:joined`: channel messages may not arrive.
    private(set) var isDegraded = false

    @ObservationIgnored let api: RaftAPI
    @ObservationIgnored let preferences: AppPreferences
    /// A membership event (`server:member-*`, `server:deleted`) for this user arrived.
    @ObservationIgnored var onMembershipChange: (@MainActor () -> Void)?
    @ObservationIgnored private let realtime: (any RealtimeSource)?
    @ObservationIgnored private var conversations: [String: ConversationStore] = [:]
    @ObservationIgnored private var conversationOrder: [String] = []
    @ObservationIgnored private var threads: [String: ThreadStore] = [:]
    @ObservationIgnored private var threadOrder: [String] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var roomsJoinedCount = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored let cacheLimit = 12

    init(
        serverId: String,
        currentUserId: String,
        api: RaftAPI,
        preferences: AppPreferences,
        realtime: (any RealtimeSource)?
    ) {
        self.serverId = serverId
        self.currentUserId = currentUserId
        self.api = api
        self.preferences = preferences
        self.realtime = realtime
        channelList = ChannelListStore(api: api, serverId: serverId, currentUserId: currentUserId)
        activity = ActivityStore(api: api, currentUserId: currentUserId)
        directory = DirectoryStore(api: api, serverId: serverId)
        homeExtras = HomeExtrasStore(api: api, serverId: serverId, preferences: preferences)
        attachments = AttachmentStore(api: api)
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    /// Lost a connection it had (not the first connect at launch).
    var isOffline: Bool {
        switch connection {
        case .connected, .idle: false
        case .connecting: lastConnectedAt != nil
        case .reconnecting, .stopped: true
        }
    }

    // MARK: Lifecycle

    /// Connects the socket and loads Home.
    func start() async {
        guard !started else { return }
        started = true
        if let realtime {
            let events = await realtime.events()
            let statuses = await realtime.statuses()
            tasks.append(Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.handle(event)
                }
            })
            tasks.append(Task { [weak self] in
                for await status in statuses {
                    self?.connection = status
                }
            })
            await realtime.start()
        }
        await channelList.load()
    }

    func stop() async {
        for task in tasks { task.cancel() }
        tasks = []
        started = false
        for store in conversations.values { store.isVisible = false }
        await realtime?.stop(reason: "workspace closed")
    }

    #if DEBUG
    /// `SimulatedOutage` began: drop the live socket, as a lost network would.
    func dropConnection() async {
        await realtime?.reconnectNow()
    }
    #endif

    /// The app came back to the foreground, or the network came back: skip a reconnect wait
    /// and refresh counts.
    func resumeForeground() async {
        if case .reconnecting = connection { await realtime?.reconnectNow() }
        channelList.scheduleUnreadRefresh()
        activity.scheduleRefresh()
    }

    // MARK: Stores

    /// The store of a channel or DM conversation (kept while it is in the recent cache).
    func conversation(for ref: ConversationRef) -> ConversationStore {
        if let store = conversations[ref.channelId] {
            touch(ref.channelId, in: &conversationOrder)
            if !ref.title.isEmpty { store.title = ref.title }
            let preview = channelList.isPreview(ref.channelId)
            if store.isPreview != preview { store.isPreview = preview }
            return store
        }
        let lastRead = ref.lastReadSeq ?? channelList.row(id: ref.channelId)?.maxReadSeq
        let store = ConversationStore(
            channelId: ref.channelId,
            kind: ref.kind,
            title: ref.title,
            lastReadSeq: lastRead,
            currentUserId: currentUserId,
            api: api,
            preferences: preferences
        )
        store.isPreview = channelList.isPreview(ref.channelId)
        register(store)
        return store
    }

    /// The store of a thread screen.
    func thread(for ref: ThreadRef) -> ThreadStore {
        if let store = threads[ref.parentMessageId] {
            touch(ref.parentMessageId, in: &threadOrder)
            return store
        }
        let store = ThreadStore(ref: ref, api: api, preferences: preferences) { [weak self] threadChannelId, parentMessageId in
            self?.threadReplies(threadChannelId: threadChannelId, parentMessageId: parentMessageId, title: ref.title, parentChannelId: ref.parentChannelId)
        }
        store.joiner = realtime
        threads[ref.parentMessageId] = store
        touch(ref.parentMessageId, in: &threadOrder)
        trim(&threads, order: &threadOrder) { $0.replies?.isVisible != true }
        return store
    }

    private func threadReplies(threadChannelId: String, parentMessageId: String, title: String, parentChannelId: String) -> ConversationStore {
        if let store = conversations[threadChannelId] {
            let preview = channelList.isPreview(parentChannelId)
            if store.isPreview != preview { store.isPreview = preview }
            return store
        }
        let store = ConversationStore(
            channelId: threadChannelId,
            kind: .thread,
            title: title,
            threadParentMessageId: parentMessageId,
            currentUserId: currentUserId,
            api: api,
            preferences: preferences
        )
        store.isPreview = channelList.isPreview(parentChannelId)
        register(store)
        return store
    }

    /// After a join: the channel's open stores (and its threads') are no longer previews.
    func endPreview(channelId: String) {
        conversations[channelId]?.isPreview = false
        for store in threads.values where store.parentChannelId == channelId {
            store.replies?.isPreview = false
        }
    }

    /// After a leave: drops the channel's conversation and thread stores (pending sends with them).
    func forgetConversation(channelId: String) {
        var dropped: Set<String> = [channelId]
        for (key, store) in threads where store.parentChannelId == channelId {
            if let replies = store.replies { dropped.insert(replies.channelId) }
            threads[key] = nil
        }
        threadOrder.removeAll { threads[$0] == nil }
        for id in dropped {
            conversations[id]?.isVisible = false
            conversations[id] = nil
        }
        conversationOrder.removeAll { dropped.contains($0) }
    }

    /// Joins and leaves this socket's room for a channel (after a REST join or leave).
    func joinRoom(_ channelId: String) async { await realtime?.joinChannel(channelId) }
    func leaveRoom(_ channelId: String) async { await realtime?.leaveChannel(channelId) }

    private func register(_ store: ConversationStore) {
        store.onRead = { [weak self] channelId, seq in
            self?.channelList.noteLocallyRead(channelId: channelId, seq: seq)
        }
        conversations[store.channelId] = store
        touch(store.channelId, in: &conversationOrder)
        trim(&conversations, order: &conversationOrder) { !$0.isVisible }
    }

    /// Open stores (tests, diagnostics).
    var openConversationIds: [String] { conversationOrder }
    var openThreadParentIds: [String] { threadOrder }

    private func touch(_ key: String, in order: inout [String]) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Drops the least recently used entries past the limit (never one still on screen).
    private func trim<Store>(_ stores: inout [String: Store], order: inout [String], evictable: (Store) -> Bool) {
        var index = 0
        while stores.count > cacheLimit, index < order.count {
            let key = order[index]
            if let store = stores[key], evictable(store) {
                stores[key] = nil
                order.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    #if DEBUG
    func debugSet(connection: RealtimeStatus) {
        self.connection = connection
    }

    /// Registers a seeded store so `conversation(for:)` returns it.
    func debugRegister(_ store: ConversationStore) {
        register(store)
    }
    #endif

    // MARK: Event routing

    /// Routes one socket event to the stores it changes.
    func handle(_ event: RealtimeEvent) async {
        switch event {
        case .roomsJoined:
            isDegraded = false
            roomsJoinedCount += 1
            if roomsJoinedCount > 1 { await resync() }
        case .roomsJoinFailed:
            isDegraded = true
        case .messageNew(let message):
            receive(message)
        case .syncResume(let response):
            for message in response.messages {
                if let channelId = message.channelId { conversations[channelId]?.receive(message) }
            }
            if !response.messages.isEmpty {
                channelList.scheduleUnreadRefresh()
                channelList.scheduleDirectMessageRefresh()
                activity.scheduleRefresh()
            }
        case .messageUpdated(let message), .threadReplyUpdated(let message):
            for store in conversations.values { store.applyUpdate(message) }
            threads[message.id]?.applyParentUpdate(message)
        case .threadUpdated(let update):
            for store in conversations.values { store.applyThreadUpdate(update) }
            threads[update.parentMessageId]?.applyThreadUpdate(update)
            channelList.scheduleUnreadRefresh()
            activity.scheduleRefresh()
        case .readStateUpdated(let update):
            applyReadState(update)
        case .readStateUpdatedBulk(let updates):
            for update in updates { applyReadState(update) }
        case .channelUpdated(let channelId, let raw):
            await channelList.applyChannelUpdate(channelId: channelId, raw: raw)
            if let channelId, let store = conversations[channelId], let row = channelList.row(id: channelId), !row.title.isEmpty {
                store.title = row.title
            }
        case .directMessageNew(let channelId):
            // Not in the DM's room yet (rooms are joined at connect): join, then re-read DMs.
            await realtime?.joinChannel(channelId)
            channelList.scheduleDirectMessageRefresh()
        case .activityChanged(let eventServerId, _):
            if eventServerId == nil || eventServerId == serverId { activity.scheduleRefresh() }
        case .agentTyping(let typing):
            guard typing.serverId == serverId else { return }
            for store in conversations.values { store.applyTyping(typing) }
        case .serverMembership(_, let eventServerId, let userId):
            if (eventServerId == nil || eventServerId == serverId) && (userId == nil || userId == currentUserId) {
                onMembershipChange?()
            }
        default:
            break
        }
    }

    private func receive(_ message: Message) {
        let store = message.channelId.flatMap { conversations[$0] }
        let viewing = (store?.isVisible ?? false) && !preferences.readOnly
        channelList.noteMessage(message, viewing: viewing)
        store?.receive(message)
        activity.noteMessage(message)
    }

    private func applyReadState(_ update: ReadStateUpdate) {
        if let eventServerId = update.serverId, eventServerId != serverId { return }
        channelList.applyReadState(update)
        activity.applyReadState(update)
    }

    /// After a reconnect: what changed while the socket was down.
    private func resync() async {
        await channelList.refresh()
        activity.scheduleRefresh()
        for store in conversations.values where store.phase == .loaded {
            await store.catchUp()
        }
    }
}
