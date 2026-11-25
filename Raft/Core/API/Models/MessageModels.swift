import Foundation

struct MessageAttachment: Sendable, Hashable, Decodable, Identifiable {
    var id: String
    var filename: String
    var mimeType: String
    var sizeBytes: Int64
    var width: Int?
    var height: Int?
    var thumbnailUrl: String?
    var commentCount: Int

    private enum CodingKeys: String, CodingKey { case id, filename, mimeType, sizeBytes, width, height, thumbnailUrl, commentCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredId(.id)
        filename = c.lenient(.filename) ?? ""
        mimeType = c.lenient(.mimeType) ?? "application/octet-stream"
        sizeBytes = c.flexibleInt64(.sizeBytes) ?? 0
        width = c.flexibleInt(.width)
        height = c.flexibleInt(.height)
        thumbnailUrl = c.lenient(.thumbnailUrl)
        commentCount = c.flexibleInt(.commentCount) ?? 0
    }

    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
}

struct MessageReaction: Sendable, Hashable, Decodable {
    var emoji: String
    var count: Int
    var reactorIds: [String]
    var reactorNames: [String]

    private enum CodingKeys: String, CodingKey { case emoji, count, reactorIds, reactorNames }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoji = c.lenient(.emoji) ?? ""
        reactorIds = c.lenient(.reactorIds) ?? []
        reactorNames = c.lenient(.reactorNames) ?? []
        count = c.flexibleInt(.count) ?? reactorIds.count
    }
}

/// `{ type, id, name }`: a mention in a message, and in a send body.
struct MessageMention: Sendable, Hashable, Codable {
    /// Sent: `user`, `agent` or `external` (anything else is refused). Received: also others.
    var type: String
    var id: String
    var name: String

    init(type: String, id: String, name: String) {
        self.type = type
        self.id = id
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case type, id, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(.type) ?? ""
        id = c.lenient(.id) ?? ""
        name = c.lenient(.name) ?? ""
    }
}

/// The thread under a message, as embedded in the message.
struct MessageThreadSummary: Sendable, Hashable, Decodable {
    var threadChannelId: String
    var replyCount: Int
    var unreadCount: Int

    private enum CodingKeys: String, CodingKey { case threadChannelId, replyCount, unreadCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadChannelId = try c.requiredId(.threadChannelId)
        replyCount = c.flexibleInt(.replyCount) ?? 0
        unreadCount = c.flexibleInt(.unreadCount) ?? 0
    }
}

struct MessageConversationContext: Sendable, Hashable, Decodable {
    var channelType: String?
    var parentMessageId: String?
    var parentChannelId: String?
    var parentChannelType: String?
    var taskId: String?

    private enum CodingKeys: String, CodingKey { case channelType, parentMessageId, parentChannelId, parentChannelType, taskId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelType = c.lenient(.channelType)
        parentMessageId = c.lenient(.parentMessageId)
        parentChannelId = c.lenient(.parentChannelId)
        parentChannelType = c.lenient(.parentChannelType)
        taskId = c.lenient(.taskId)
    }
}

/// A message as the REST routes and the socket send it.
struct Message: Sendable, Hashable, Decodable, Identifiable {
    var id: String
    var seq: Int64?
    var channelId: String?
    /// `user`, `agent`, `system`, ...
    var senderType: String
    var senderId: String
    var senderName: String?
    var senderDescription: String?
    var senderMembershipStatus: String?
    var messageType: String?
    var content: String
    /// The sender's client id for an optimistic send (echoed back).
    var randomId: String?
    var threadId: String?
    var createdAt: String?
    var updatedAt: String?
    var deletedAt: String?
    var attachments: [MessageAttachment]
    var reactions: [MessageReaction]
    var mentions: [MessageMention]
    var replyCount: Int?
    var threadSummary: MessageThreadSummary?
    var conversationContext: MessageConversationContext?
    /// Kept as raw JSON until the UI needs them.
    var actionMetadata: JSONValue?
    var commentRef: JSONValue?
    var forwardBundle: JSONValue?
    var externalAuthor: JSONValue?
    var delegatedBy: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id, seq, channelId, senderType, senderId, senderName, senderDescription, senderMembershipStatus
        case messageType, content, randomId, threadId, createdAt, updatedAt, deletedAt, attachments, reactions
        case mentions, replyCount, threadSummary, conversationContext, actionMetadata, commentRef, forwardBundle
        case externalAuthor, delegatedBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredId(.id)
        seq = c.flexibleInt64(.seq)
        channelId = c.lenient(.channelId)
        senderType = c.lenient(.senderType) ?? ""
        senderId = c.lenient(.senderId) ?? ""
        senderName = c.lenient(.senderName)
        senderDescription = c.lenient(.senderDescription)
        senderMembershipStatus = c.lenient(.senderMembershipStatus)
        messageType = c.lenient(.messageType)
        content = c.lenient(.content) ?? ""
        randomId = c.lenient(.randomId)
        threadId = c.lenient(.threadId)
        createdAt = c.lenient(.createdAt)
        updatedAt = c.lenient(.updatedAt)
        deletedAt = c.lenient(.deletedAt)
        attachments = c.lenientArray(.attachments)
        reactions = c.lenientArray(.reactions)
        mentions = c.lenientArray(.mentions)
        replyCount = c.flexibleInt(.replyCount)
        threadSummary = c.lenient(.threadSummary)
        conversationContext = c.lenient(.conversationContext)
        actionMetadata = c.nonNullJSON(.actionMetadata)
        commentRef = c.nonNullJSON(.commentRef)
        forwardBundle = c.nonNullJSON(.forwardBundle)
        externalAuthor = c.nonNullJSON(.externalAuthor)
        delegatedBy = c.nonNullJSON(.delegatedBy)
    }

    var isDeleted: Bool { !(deletedAt ?? "").isEmpty }
}

/// `GET messages/channel/{id}`.
struct MessagePage: Sendable, Hashable, Decodable {
    var messages: [Message]
    /// The plan hides older history.
    var historyLimited: Bool
    var threadSummariesByParentMessageId: [String: ThreadSummary]
    var channelArchived: Bool?
    var messageWindow: JSONValue?
    /// Present when a short page reached the plan's history cutoff: what the cutoff hides.
    var hiddenHistory: HiddenHistory?
    /// `X-Sync-Horizon` of a latest page (no `before`/`after`), taken before the page was read: a
    /// client whose first history read this is can start `sync:resume` from it
    /// (`RealtimeClient.setResumePoint`). Not part of the body.
    var syncHorizon: String?

    private enum CodingKeys: String, CodingKey {
        case messages, historyLimited, threadSummariesByParentMessageId, channelArchived, messageWindow, hiddenHistory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.lenientArray(.messages)
        historyLimited = c.lenient(.historyLimited) ?? false
        threadSummariesByParentMessageId = c.lenientMap(.threadSummariesByParentMessageId)
        channelArchived = c.lenient(.channelArchived)
        messageWindow = c.nonNullJSON(.messageWindow)
        hiddenHistory = c.lenient(.hiddenHistory)
    }
}

/// `hiddenHistory` of a message page: a count and a faded preview of the newest hidden messages.
struct HiddenHistory: Sendable, Hashable, Decodable {
    var hiddenCount: Int
    var hiddenCountCapped: Bool
    /// Preview rows, kept raw (the web renders them faded behind the paywall).
    var latest: [JSONValue]

    private enum CodingKeys: String, CodingKey { case hiddenCount, hiddenCountCapped, latest }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenCount = c.lenient(.hiddenCount) ?? 0
        hiddenCountCapped = c.lenient(.hiddenCountCapped) ?? false
        latest = c.lenient(.latest) ?? []
    }
}

/// `GET messages/context/{messageId}?channelId=`: a window around one message.
struct MessageContextPage: Sendable, Hashable, Decodable {
    var channelId: String
    var targetMessageId: String
    var hasOlder: Bool
    var hasNewer: Bool
    var messages: [Message]
    var historyLimited: Bool
    var channelArchived: Bool
    /// Thread previews of the window's messages (as `MessagePage`).
    var threadSummariesByParentMessageId: [String: ThreadSummary]

    private enum CodingKeys: String, CodingKey {
        case channelId, targetMessageId, hasOlder, hasNewer, messages, historyLimited, channelArchived, threadSummariesByParentMessageId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelId = c.lenient(.channelId) ?? ""
        targetMessageId = c.lenient(.targetMessageId) ?? ""
        hasOlder = c.lenient(.hasOlder) ?? false
        hasNewer = c.lenient(.hasNewer) ?? false
        messages = c.lenientArray(.messages)
        historyLimited = c.lenient(.historyLimited) ?? false
        channelArchived = c.lenient(.channelArchived) ?? false
        threadSummariesByParentMessageId = c.lenientMap(.threadSummariesByParentMessageId)
    }
}

/// `POST v2/messages` body. `randomId`, `mentions` and `timezone` are left out when nil.
/// Server contract (server `routes/messages.ts` `createHumanMessage`, v1.33.1):
/// `channelId` (UUID), `content` (non-blank, ≤ 32 000 chars), `attachmentIds?` (UUIDs), `asTask?`,
/// `randomId?` (1–128 chars, the optimistic-send key), `mentions?` (`{ type: user | agent | external,
/// id: UUID, name }`), `timezone?` (IANA, best effort). Refusals: 400 `invalid_request`,
/// `content_required`, `message_too_long`, `mentions_invalid`, `mention_binding_conflict`.
struct SendMessageBody: Encodable, Sendable, Hashable {
    static let maxContentLength = 32_000
    static let maxRandomIdLength = 128

    var channelId: String
    var content: String
    var attachmentIds: [String] = []
    var asTask = false
    var randomId: String?
    var mentions: [MessageMention]?
    var timezone: String? = TimeZone.current.identifier

    private enum CodingKeys: String, CodingKey { case channelId, content, attachmentIds, asTask, randomId, mentions, timezone }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelId, forKey: .channelId)
        try c.encode(content, forKey: .content)
        try c.encode(attachmentIds, forKey: .attachmentIds)
        try c.encode(asTask, forKey: .asTask)
        try c.encodeIfPresent(randomId, forKey: .randomId)
        try c.encodeIfPresent(mentions, forKey: .mentions)
        try c.encodeIfPresent(timezone, forKey: .timezone)
    }
}

/// `POST v2/messages` answer: `{ message, pendingMentionActions?, unresolvedMentionHandles?,
/// deliveryWarnings? }` (the optional keys only when non-empty), or a bare message (v1).
struct SendMessageResult: Sendable, Hashable, Decodable {
    var message: Message
    var pendingMentionActions: JSONValue?
    var unresolvedMentionHandles: [String]
    var deliveryWarnings: JSONValue?

    private enum CodingKeys: String, CodingKey { case message, pendingMentionActions, unresolvedMentionHandles, deliveryWarnings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let message = c.lenient(.message, as: Message.self) {
            self.message = message
            pendingMentionActions = c.nonNullJSON(.pendingMentionActions)
            unresolvedMentionHandles = c.lenient(.unresolvedMentionHandles) ?? []
            deliveryWarnings = c.nonNullJSON(.deliveryWarnings)
        } else {
            message = try Message(from: decoder)
            pendingMentionActions = nil
            unresolvedMentionHandles = []
            deliveryWarnings = nil
        }
    }
}

/// A thread's summary (`GET channels/{id}/threads`, keyed by parent message id).
struct ThreadSummary: Sendable, Hashable, Decodable {
    var threadChannelId: String?
    var parentMessageId: String?
    var replyCount: Int
    var unreadCount: Int?
    var lastReplyAt: String?
    var participantIds: [String]
    /// The newest replies, oldest first (the thread preview under the parent).
    var latestReplies: [ThreadReplyPreview]
    /// This person follows the thread.
    var followed: Bool?
    var raw: JSONValue

    private enum CodingKeys: String, CodingKey { case threadChannelId, parentMessageId, replyCount, unreadCount, lastReplyAt, participantIds, latestReplies, followed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadChannelId = c.lenient(.threadChannelId)
        parentMessageId = c.lenient(.parentMessageId)
        replyCount = c.flexibleInt(.replyCount) ?? 0
        unreadCount = c.flexibleInt(.unreadCount)
        lastReplyAt = c.lenient(.lastReplyAt)
        participantIds = c.lenient(.participantIds) ?? []
        latestReplies = c.lenientArray(.latestReplies)
        followed = c.lenient(.followed)
        raw = (try? JSONValue(from: decoder)) ?? .null
    }
}

/// One of a thread summary's `latestReplies` (server `ThreadSummaryLatestReply`).
struct ThreadReplyPreview: Sendable, Hashable, Decodable, Identifiable {
    var messageId: String
    var seq: Int64?
    var preview: String
    var senderId: String
    var senderType: String
    var senderName: String?
    var senderAvatarUrl: String?
    var createdAt: String?

    var id: String { messageId }

    private enum CodingKeys: String, CodingKey { case messageId, seq, preview, senderId, senderType, senderName, senderDisplayName, senderAvatarUrl, createdAt }

    init(messageId: String, seq: Int64?, preview: String, senderId: String, senderType: String, senderName: String?, senderAvatarUrl: String? = nil, createdAt: String?) {
        self.messageId = messageId
        self.seq = seq
        self.preview = preview
        self.senderId = senderId
        self.senderType = senderType
        self.senderName = senderName
        self.senderAvatarUrl = senderAvatarUrl
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.requiredId(.messageId)
        seq = c.flexibleInt64(.seq)
        preview = c.lenient(.preview) ?? ""
        senderId = c.lenient(.senderId) ?? ""
        senderType = c.lenient(.senderType) ?? "user"
        senderName = c.lenient(.senderDisplayName) ?? c.lenient(.senderName)
        senderAvatarUrl = c.lenient(.senderAvatarUrl)
        createdAt = c.lenient(.createdAt)
    }

    /// The preview of a full reply message (`thread:updated` `latestReply`).
    init(_ message: Message) {
        self.init(
            messageId: message.id, seq: message.seq, preview: message.content, senderId: message.senderId,
            senderType: message.senderType, senderName: message.senderName, createdAt: message.createdAt
        )
    }
}

/// `POST channels/{id}/threads { parentMessageId }`.
struct CreateThreadResult: Sendable, Hashable, Decodable {
    var threadChannelId: String
    var parentMessageId: String?
    var created: Bool?
    var replyCount: Int?

    private enum CodingKeys: String, CodingKey { case threadChannelId, parentMessageId, created, replyCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadChannelId = try c.requiredId(.threadChannelId)
        parentMessageId = c.lenient(.parentMessageId)
        created = c.lenient(.created)
        replyCount = c.flexibleInt(.replyCount)
    }
}

/// `GET channels/inbox?filter=all|unread|mentions|unread_mentions&limit&offset` (server
/// `routes/channels.ts`, `channelService.InboxItemsResult`): `{ items, groups, hasMore, totalCount,
/// totalUnreadCount, activeUnreadCount }`.
struct InboxPage: Sendable, Hashable, Decodable {
    var items: [InboxItem]
    var hasMore: Bool
    var totalCount: Int?
    var totalUnreadCount: Int?
    var activeUnreadCount: Int?

    private enum CodingKeys: String, CodingKey { case items, hasMore, totalCount, totalUnreadCount, activeUnreadCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lenientArray(.items)
        hasMore = c.lenient(.hasMore) ?? false
        totalCount = c.flexibleInt(.totalCount)
        totalUnreadCount = c.flexibleInt(.totalUnreadCount)
        activeUnreadCount = c.flexibleInt(.activeUnreadCount)
    }
}

/// One Activity row. The server sends a union (`channelService.InboxItem`):
/// - `channel` / `dm`: `channelId, channelName, channelType, lastMessageId, lastMessageAt,
///   lastMessagePreview, lastMessageSenderName, …`
/// - `thread` / `task`: `threadChannelId, parentMessageId (null for task), parentChannelId,
///   parentChannelName, parentChannelType, parentMessagePreview, latestActivityPreview,
///   latestActivitySenderName, latestActivityMessageId, lastActivityAt, replyCount, …`
/// - object rows (apps such as Artifacts) carry other fields; they decode with what is shared.
/// Both arms: `unreadCount, hasMention, firstUnreadMessageId, firstMentionMessageId,
/// latestActivitySeq, maxReadSeq?, readStateVersion?`.
struct InboxItem: Sendable, Hashable, Decodable, Identifiable {
    var kind: String
    var channelId: String?
    var channelName: String?
    var channelType: String?
    var threadChannelId: String?
    var parentMessageId: String?
    var parentChannelId: String?
    var parentChannelName: String?
    var parentChannelType: String?
    var parentMessagePreview: String?
    /// `lastMessagePreview` (channel arm) or `latestActivityPreview` (thread arm).
    var preview: String?
    /// `lastMessageSenderName` or `latestActivitySenderName`.
    var senderName: String?
    /// `lastMessageId` or `latestActivityMessageId`.
    var latestMessageId: String?
    /// `lastMessageAt` or `lastActivityAt`.
    var activityAt: String?
    var latestActivitySeq: Int64?
    var firstUnreadMessageId: String?
    var firstMentionMessageId: String?
    var unreadCount: Int
    var hasMention: Bool
    var replyCount: Int?
    var readStateVersion: Int64?
    /// `lastMessageSenderType/Id` or `latestActivitySenderType/Id`.
    var senderType: String?
    var senderId: String?
    var isFollowing: Bool?
    /// Task rows: the task's number ("#1"), title and status.
    var taskNumber: Int?
    var taskTitle: String?
    var taskStatus: String?

    private enum CodingKeys: String, CodingKey {
        case kind, channelId, channelName, channelType, threadChannelId, parentMessageId, parentChannelId
        case parentChannelName, parentChannelType, parentMessagePreview
        case lastMessagePreview, latestActivityPreview, lastMessageSenderName, latestActivitySenderName
        case lastMessageSenderType, latestActivitySenderType, lastMessageSenderId, latestActivitySenderId, isFollowing
        case lastMessageId, latestActivityMessageId, lastMessageAt, lastActivityAt, latestActivityAt, lastReplyAt, updatedAt, latestActivitySeq
        case firstUnreadMessageId, firstMentionMessageId, unreadCount, hasMention, replyCount, readStateVersion
        case taskNumber, taskTitle, taskStatus
        case id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(.kind) ?? ""
        channelId = c.lenient(.channelId)
        channelName = c.lenient(.channelName)
        channelType = c.lenient(.channelType)
        threadChannelId = c.lenient(.threadChannelId)
        parentMessageId = c.lenient(.parentMessageId)
        parentChannelId = c.lenient(.parentChannelId)
        parentChannelName = c.lenient(.parentChannelName)
        parentChannelType = c.lenient(.parentChannelType)
        parentMessagePreview = c.lenient(.parentMessagePreview)
        preview = c.lenient(.lastMessagePreview) ?? c.lenient(.latestActivityPreview)
        senderName = c.lenient(.lastMessageSenderName) ?? c.lenient(.latestActivitySenderName)
        latestMessageId = c.lenient(.lastMessageId) ?? c.lenient(.latestActivityMessageId)
        activityAt = c.timestamp(.lastMessageAt) ?? c.timestamp(.lastActivityAt) ?? c.timestamp(.latestActivityAt)
            ?? c.timestamp(.lastReplyAt) ?? c.timestamp(.updatedAt)
        latestActivitySeq = c.flexibleInt64(.latestActivitySeq)
        firstUnreadMessageId = c.lenient(.firstUnreadMessageId)
        firstMentionMessageId = c.lenient(.firstMentionMessageId)
        unreadCount = c.flexibleInt(.unreadCount) ?? 0
        hasMention = c.lenient(.hasMention) ?? false
        replyCount = c.flexibleInt(.replyCount)
        readStateVersion = c.flexibleInt64(.readStateVersion)
        senderType = c.lenient(.lastMessageSenderType) ?? c.lenient(.latestActivitySenderType)
        senderId = c.lenient(.lastMessageSenderId) ?? c.lenient(.latestActivitySenderId)
        isFollowing = c.lenient(.isFollowing)
        taskNumber = c.flexibleInt(.taskNumber)
        taskTitle = c.lenient(.taskTitle)
        taskStatus = c.lenient(.taskStatus)
        objectId = c.lenient(.id)
        guard scopeChannelId != nil || objectId != nil else {
            throw DecodingError.keyNotFound(CodingKeys.channelId, .init(codingPath: c.codingPath, debugDescription: "row without an id"))
        }
    }

    private var objectId: String?

    /// Thread and task rows are about their own conversation channel.
    var isSubConversation: Bool { kind == "thread" || kind == "task" }

    /// The conversation the row is about (the server's `inboxItemScopeChannelId`).
    var scopeChannelId: String? { isSubConversation ? threadChannelId : channelId }

    var id: String { "\(kind):\(scopeChannelId ?? objectId ?? "")" }

    /// Title for a list: the channel, or the thread's parent channel.
    var title: String {
        (isSubConversation ? parentChannelName : channelName) ?? ""
    }
}

/// An uploaded file (`POST attachments/upload` → `{ attachments: [...] }`).
struct UploadedAttachment: Sendable, Hashable, Decodable, Identifiable {
    var id: String
    var filename: String
    var mimeType: String?
    var sizeBytes: Int64?
    var raw: JSONValue

    private enum CodingKeys: String, CodingKey { case id, filename, mimeType, sizeBytes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredId(.id)
        filename = c.lenient(.filename) ?? ""
        mimeType = c.lenient(.mimeType)
        sizeBytes = c.flexibleInt64(.sizeBytes)
        raw = (try? JSONValue(from: decoder)) ?? .null
    }
}

/// A short-lived download URL (`attachments/urls`, `attachments/{id}/url`).
struct AttachmentURL: Sendable, Hashable, Decodable {
    var id: String?
    var url: URL
    var expiresAt: String?

    private enum CodingKeys: String, CodingKey { case id, url, expiresAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let text = c.lenient(.url, as: String.self), let url = URL(string: text) else {
            throw DecodingError.keyNotFound(CodingKeys.url, .init(codingPath: c.codingPath, debugDescription: "url"))
        }
        self.url = url
        id = c.lenient(.id)
        expiresAt = c.lenient(.expiresAt)
    }
}

/// A file to upload.
struct UploadFile: Sendable, Hashable {
    var filename: String
    var mimeType: String
    var data: Data
}

extension KeyedDecodingContainer {
    /// Raw JSON at `key`, nil when absent or null.
    func nonNullJSON(_ key: Key) -> JSONValue? {
        guard let value = lenient(key, as: JSONValue.self), !value.isNull else { return nil }
        return value
    }
}
