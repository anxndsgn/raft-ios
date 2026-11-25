import Foundation
import Observation

/// What the conversation knows about the thread under one of its messages.
struct ThreadInfo: Hashable, Sendable {
    var threadChannelId: String?
    var replyCount: Int
    var lastReplyAt: String?
    var unreadCount: Int?
    /// The newest replies, oldest first (at most two are shown).
    var latestReplies: [ThreadReplyPreview] = []
    var followed: Bool?
}

/// A message sent from this device that the server has not confirmed yet (or refused).
struct PendingSend: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case sending
        case failed(String)
    }

    /// The optimistic-send key (`randomId` of `POST v2/messages`); the server echoes it on the
    /// message, which is how the confirmed copy replaces this one.
    let randomId: String
    let channelId: String
    var content: String
    var mentions: [MessageMention]
    var state: State
    let createdAt: Date
    var attachmentIds: [String] = []
    /// Local names of the files sent with it (shown while pending).
    var attachmentNames: [String] = []
    var asTask = false

    var id: String { randomId }
}

enum TimelineItem: Identifiable, Hashable, Sendable {
    case message(Message)
    case pending(PendingSend)

    var id: String {
        switch self {
        case .message(let message): "m:\(message.id)"
        case .pending(let pending): "p:\(pending.randomId)"
        }
    }
}

/// One conversation (channel, DM or a thread's replies): history paged by `seq`, live socket
/// messages and edits, agent typing, optimistic sends keyed by `randomId`, read receipts.
@MainActor
@Observable
final class ConversationStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let channelId: String
    let kind: ConversationKind
    var title: String
    /// For a thread's replies: the root message (typing lines for the thread are keyed by it).
    let threadParentMessageId: String?

    private(set) var phase: Phase = .idle
    /// Ascending by `seq`.
    private(set) var messages: [Message] = []
    private(set) var pending: [PendingSend] = []
    /// Threads under this conversation's messages, by parent message id.
    private(set) var threads: [String: ThreadInfo] = [:]
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    /// The plan hides older history (`historyLimited`); `hiddenHistory` says how much.
    private(set) var historyLimited = false
    private(set) var hiddenHistory: HiddenHistory?
    /// A jump (Activity → message) loaded a window away from the newest messages; live messages
    /// are not appended until `jumpToLatest()`.
    private(set) var isDetached = false
    private(set) var focusMessageId: String?
    /// Agents about to post here, in the order their calls started.
    private(set) var typingAgentIds: [String] = []
    /// Read point when the conversation opened: the "new messages" divider goes after it.
    private(set) var unreadMarkerSeq: Int64?
    private(set) var lastReadSeq: Int64?
    var errorMessage: String?

    /// The conversation is on screen: live messages do not count as unread and are read.
    var isVisible = false {
        didSet {
            if isVisible && !oldValue { scheduleMarkRead() }
        }
    }

    @ObservationIgnored let currentUserId: String
    @ObservationIgnored private let api: RaftAPI
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored var pageSize = 50
    @ObservationIgnored var catchUpPageSize = 100
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Called after a read receipt was accepted (`channelId`, `seq`).
    @ObservationIgnored var onRead: ((String, Int64) -> Void)?
    @ObservationIgnored let markReadCoalescer = Coalescer(delay: .seconds(1))
    @ObservationIgnored private var typingEntries: [String: TypingEntry] = [:]
    @ObservationIgnored private var typingPrune: Task<Void, Never>?
    @ObservationIgnored private var markingRead = false

    private struct TypingEntry {
        var agentId: String
        var startedAt: Date
        var deadline: Date
    }

    init(
        channelId: String,
        kind: ConversationKind,
        title: String,
        threadParentMessageId: String? = nil,
        lastReadSeq: Int64? = nil,
        currentUserId: String,
        api: RaftAPI,
        preferences: AppPreferences
    ) {
        self.channelId = channelId
        self.kind = kind
        self.title = title
        self.threadParentMessageId = threadParentMessageId
        self.lastReadSeq = lastReadSeq
        unreadMarkerSeq = lastReadSeq
        self.currentUserId = currentUserId
        self.api = api
        self.preferences = preferences
    }

    /// Server messages then this device's pending sends.
    var timeline: [TimelineItem] {
        messages.map(TimelineItem.message) + pending.map(TimelineItem.pending)
    }

    var newestSeq: Int64? { messages.last(where: { $0.seq != nil })?.seq }
    var oldestSeq: Int64? { messages.first(where: { $0.seq != nil })?.seq }

    func message(id: String) -> Message? { messages.first { $0.id == id } }

    // MARK: Loading

    /// The newest page, or the window around `focusMessageId` when it is not in that page.
    func start(focusMessageId: String? = nil) async {
        if phase == .loaded, focusMessageId == nil { return }
        await loadLatest()
        if let focusMessageId, message(id: focusMessageId) == nil {
            await loadAround(messageId: focusMessageId)
        } else {
            self.focusMessageId = focusMessageId
        }
    }

    func loadLatest() async {
        if messages.isEmpty { phase = .loading }
        do {
            let page = try await api.messages(channelId: channelId, limit: pageSize)
            messages = Self.sorted(page.messages)
            hasOlder = page.messages.count >= pageSize
            historyLimited = page.historyLimited
            hiddenHistory = page.hiddenHistory
            threads = [:]
            absorbThreads(page.threadSummariesByParentMessageId, from: page.messages)
            isDetached = false
            dropConfirmedPending()
            phase = .loaded
            scheduleMarkRead()
        } catch {
            fail(error)
        }
    }

    /// The window around one message (`messages/context`), detached from the live tail when
    /// newer messages exist.
    func loadAround(messageId: String) async {
        do {
            let page = try await api.messageContext(messageId: messageId, channelId: channelId)
            messages = Self.sorted(page.messages)
            hasOlder = page.hasOlder
            historyLimited = page.historyLimited
            absorbThreads([:], from: page.messages)
            isDetached = page.hasNewer
            focusMessageId = messageId
            phase = .loaded
        } catch {
            fail(error)
        }
    }

    func jumpToLatest() async {
        focusMessageId = nil
        await loadLatest()
    }

    func loadOlder() async {
        guard hasOlder, !isLoadingOlder, let oldest = oldestSeq else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await api.messages(channelId: channelId, limit: pageSize, before: oldest)
            merge(page.messages)
            hasOlder = page.messages.count >= pageSize
            historyLimited = page.historyLimited
            if page.hiddenHistory != nil { hiddenHistory = page.hiddenHistory }
            absorbThreads(page.threadSummariesByParentMessageId, from: page.messages)
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }

    /// After a reconnect: the messages newer than the newest held (`after`), a few pages at most;
    /// past that the newest page is reloaded.
    func catchUp() async {
        guard phase == .loaded, !isDetached else { return }
        guard let newest = newestSeq else {
            await loadLatest()
            return
        }
        var cursor = newest
        for _ in 0..<5 {
            guard let page = try? await api.messages(channelId: channelId, limit: catchUpPageSize, after: cursor) else { return }
            merge(page.messages)
            absorbThreads(page.threadSummariesByParentMessageId, from: page.messages)
            dropConfirmedPending()
            guard page.messages.count >= catchUpPageSize, let next = newestSeq, next > cursor else {
                scheduleMarkRead()
                return
            }
            cursor = next
        }
        await loadLatest()
    }

    private func fail(_ error: Error) {
        if messages.isEmpty {
            phase = .failed(ErrorText.describe(error))
        } else {
            errorMessage = ErrorText.describe(error)
        }
    }

    // MARK: Live

    /// `message:new` (or a resumed / thread `latestReply` message) for this channel.
    func receive(_ message: Message) {
        guard message.channelId == nil || message.channelId == channelId else { return }
        clearTyping(agentId: message.senderType == "agent" ? message.senderId : nil)
        if let randomId = message.randomId {
            pending.removeAll { $0.randomId == randomId }
        }
        guard !isDetached, phase == .loaded else { return }
        merge([message])
        absorbThreads([:], from: [message])
        scheduleMarkRead()
    }

    /// `message:updated` / `thread:reply_updated`: the new copy replaces the held one (edits,
    /// reactions, retractions — a deleted message keeps its row with `deletedAt`).
    func applyUpdate(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        var updated = message
        if updated.channelId == nil { updated.channelId = messages[index].channelId }
        if updated.seq == nil { updated.seq = messages[index].seq }
        messages[index] = updated
        absorbThreads([:], from: [updated])
    }

    /// `thread:updated`: the reply count under a parent held here; the newest reply when this
    /// store is that thread.
    func applyThreadUpdate(_ update: ThreadUpdate) {
        if message(id: update.parentMessageId) != nil {
            var info = threads[update.parentMessageId] ?? ThreadInfo(replyCount: 0)
            info.threadChannelId = update.threadChannelId ?? info.threadChannelId
            info.replyCount = update.replyCount
            info.lastReplyAt = update.lastReplyAt ?? info.lastReplyAt
            info.unreadCount = update.unreadCount ?? info.unreadCount
            if let reply = update.latestReply, !info.latestReplies.contains(where: { $0.messageId == reply.id }) {
                info.latestReplies = Array((info.latestReplies + [ThreadReplyPreview(reply)]).suffix(2))
            }
            threads[update.parentMessageId] = info
        }
        if kind == .thread, update.threadChannelId == channelId, let reply = update.latestReply {
            receive(reply)
        }
    }

    // MARK: Agent typing

    /// `agent:typing`: a channel line (`parentMessageId` nil) here, or this thread's line.
    func applyTyping(_ typing: AgentTyping) {
        let matches: Bool
        if let parent = typing.parentMessageId {
            matches = parent == threadParentMessageId
        } else {
            matches = kind != .thread && typing.channelId == channelId
        }
        guard matches else { return }
        let key = "\(typing.agentId)\u{0}\(typing.callId)"
        let current = now()
        if typing.isStart {
            let startedAt = typingEntries[key]?.startedAt ?? current
            typingEntries[key] = TypingEntry(agentId: typing.agentId, startedAt: startedAt, deadline: typing.deadline(now: current))
        } else {
            typingEntries[key] = nil
        }
        publishTyping()
    }

    /// Drops lines past their deadline.
    func pruneTyping() {
        let current = now()
        typingEntries = typingEntries.filter { $0.value.deadline > current }
        publishTyping()
    }

    private func clearTyping(agentId: String?) {
        guard let agentId else { return }
        let before = typingEntries.count
        typingEntries = typingEntries.filter { $0.value.agentId != agentId }
        if typingEntries.count != before { publishTyping() }
    }

    private func publishTyping() {
        var seen = Set<String>()
        let ordered = typingEntries.values.sorted { $0.startedAt < $1.startedAt }.map(\.agentId)
        typingAgentIds = ordered.filter { seen.insert($0).inserted }
        typingPrune?.cancel()
        guard let earliest = typingEntries.values.map(\.deadline).min() else { return }
        let wait = max(0.05, earliest.timeIntervalSince(now()))
        typingPrune = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.pruneTyping()
        }
    }

    // MARK: Sending

    /// Optimistic send: a pending row at once, replaced by the server's copy (matched by
    /// `randomId`, from the answer or `message:new`, whichever lands first).
    func send(_ text: String, mentions: [MessageMention] = [], attachmentIds: [String] = [], attachmentNames: [String] = [], asTask: Bool = false) async {
        guard let randomId = enqueue(text, mentions: mentions, hasAttachments: !attachmentIds.isEmpty, attachmentNames: attachmentNames, asTask: asTask) else { return }
        await deliver(randomId, attachmentIds: attachmentIds)
    }

    /// The pending row alone, synchronously (the screen calls this on the tap, before any
    /// upload or network wait); `deliver` sends it. Nil when nothing is to be sent.
    @discardableResult
    func enqueue(_ text: String, mentions: [MessageMention] = [], hasAttachments: Bool = false, attachmentNames: [String] = [], asTask: Bool = false, randomId: String? = nil, createdAt: Date? = nil) -> String? {
        guard !preferences.readOnly else {
            errorMessage = StoreError.readOnly.errorDescription
            return nil
        }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || hasAttachments else { return nil }
        guard content.count <= SendMessageBody.maxContentLength else {
            errorMessage = "That message is too long."
            return nil
        }
        let item = PendingSend(
            randomId: randomId ?? Self.makeRandomId(),
            channelId: channelId,
            content: content,
            mentions: mentions,
            state: .sending,
            createdAt: createdAt ?? now(),
            attachmentNames: attachmentNames,
            asTask: asTask
        )
        pending.append(item)
        return item.randomId
    }

    /// Sends an enqueued row with its uploaded files (ids known only after the uploads).
    func deliver(_ randomId: String, attachmentIds: [String]) async {
        guard let index = pending.firstIndex(where: { $0.randomId == randomId }) else { return }
        pending[index].attachmentIds = attachmentIds
        if pending[index].content.isEmpty && attachmentIds.isEmpty {
            // Every upload failed and there is no text: nothing left to send.
            pending.remove(at: index)
            errorMessage = L10n.t("thread_composer_attachment_upload_failed", "Upload failed")
            return
        }
        await deliver(randomId)
    }

    /// Sends a failed message again with the same `randomId`.
    func retry(_ randomId: String) async {
        guard !preferences.readOnly else {
            errorMessage = StoreError.readOnly.errorDescription
            return
        }
        guard let index = pending.firstIndex(where: { $0.randomId == randomId }), case .failed = pending[index].state else { return }
        pending[index].state = .sending
        await deliver(randomId)
    }

    func discard(_ randomId: String) {
        pending.removeAll { $0.randomId == randomId }
    }

    private func deliver(_ randomId: String) async {
        guard let item = pending.first(where: { $0.randomId == randomId }) else { return }
        let body = SendMessageBody(
            channelId: item.channelId,
            content: item.content,
            attachmentIds: item.attachmentIds,
            asTask: item.asTask,
            randomId: item.randomId,
            mentions: item.mentions.isEmpty ? nil : item.mentions
        )
        do {
            let result = try await api.sendMessage(body)
            pending.removeAll { $0.randomId == randomId }
            if isDetached {
                await jumpToLatest()
            } else if phase == .loaded {
                merge([result.message])
            }
        } catch {
            if let index = pending.firstIndex(where: { $0.randomId == randomId }) {
                pending[index].state = .failed(ErrorText.describe(error))
            }
        }
    }

    /// The server's copy arrived (page or event): its pending row goes.
    private func dropConfirmedPending() {
        let confirmed = Set(messages.compactMap(\.randomId))
        pending.removeAll { confirmed.contains($0.randomId) }
    }

    static func makeRandomId() -> String { "ios-\(UUID().uuidString.lowercased())" }

    // MARK: Reactions

    /// Adds the reaction, or removes it when this person already reacted with it. The new
    /// counts arrive with `message:updated`.
    func toggleReaction(_ emoji: String, on messageId: String) async {
        guard !preferences.readOnly else {
            errorMessage = StoreError.readOnly.errorDescription
            return
        }
        let reacted = message(id: messageId)?.reactions.contains { $0.emoji == emoji && $0.reactorIds.contains(currentUserId) } ?? false
        do {
            if reacted {
                try await api.removeReaction(messageId: messageId, emoji: emoji)
            } else {
                try await api.addReaction(messageId: messageId, emoji: emoji)
            }
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }

    // MARK: Read receipts

    func scheduleMarkRead() {
        guard isVisible, !preferences.readOnly else { return }
        markReadCoalescer.schedule { [weak self] in await self?.markReadIfNeeded() }
    }

    /// `POST channels/{id}/read { seq }` up to the newest message, when visible, attached to the
    /// live tail and not read-only.
    func markReadIfNeeded() async {
        guard isVisible, !preferences.readOnly, !isDetached, !markingRead else { return }
        guard let newest = newestSeq, newest > (lastReadSeq ?? 0) else { return }
        markingRead = true
        defer { markingRead = false }
        do {
            try await api.markRead(channelId: channelId, seq: newest)
            lastReadSeq = newest
            onRead?(channelId, newest)
        } catch {
            // Read state is retried with the next message or visit.
        }
    }

    #if DEBUG
    /// Preview gallery: a conversation state without a server round trip.
    func debugSeed(phase: Phase, messages: [Message], pending: [PendingSend] = [], hasOlder: Bool = false, loadingOlder: Bool = false, typingAgentIds: [String] = [], threads: [String: ThreadSummary] = [:]) {
        self.phase = phase
        self.messages = Self.sorted(messages)
        self.pending = pending
        self.hasOlder = hasOlder
        isLoadingOlder = loadingOlder
        self.typingAgentIds = typingAgentIds
        absorbThreads(threads, from: messages)
    }
    #endif

    // MARK: Helpers

    private func merge(_ incoming: [Message]) {
        guard !incoming.isEmpty else { return }
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for message in incoming where message.channelId == nil || message.channelId == channelId {
            byId[message.id] = message
        }
        messages = Self.sorted(Array(byId.values))
    }

    private func absorbThreads(_ summaries: [String: ThreadSummary], from messages: [Message]) {
        for (parentId, summary) in summaries {
            threads[parentId] = ThreadInfo(
                threadChannelId: summary.threadChannelId,
                replyCount: summary.replyCount,
                lastReplyAt: summary.lastReplyAt,
                unreadCount: summary.unreadCount,
                latestReplies: summary.latestReplies,
                followed: summary.followed
            )
        }
        for message in messages {
            if let summary = message.threadSummary, threads[message.id] == nil {
                threads[message.id] = ThreadInfo(
                    threadChannelId: summary.threadChannelId,
                    replyCount: summary.replyCount,
                    unreadCount: summary.unreadCount
                )
            }
        }
    }

    /// By `seq`, then creation time, then id (rows without a seq go last).
    static func sorted(_ messages: [Message]) -> [Message] {
        messages.sorted { lhs, rhs in
            switch (lhs.seq, rhs.seq) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (lhs.createdAt ?? "", lhs.id) < (rhs.createdAt ?? "", rhs.id)
            }
        }
    }
}
