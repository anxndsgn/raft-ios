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

    private enum CodingKeys: String, CodingKey { case messages, historyLimited, threadSummariesByParentMessageId, channelArchived, messageWindow }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.lenientArray(.messages)
        historyLimited = c.lenient(.historyLimited) ?? false
        threadSummariesByParentMessageId = c.lenientMap(.threadSummariesByParentMessageId)
        channelArchived = c.lenient(.channelArchived)
        messageWindow = c.nonNullJSON(.messageWindow)
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

    private enum CodingKeys: String, CodingKey { case channelId, targetMessageId, hasOlder, hasNewer, messages, historyLimited, channelArchived }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelId = c.lenient(.channelId) ?? ""
        targetMessageId = c.lenient(.targetMessageId) ?? ""
        hasOlder = c.lenient(.hasOlder) ?? false
        hasNewer = c.lenient(.hasNewer) ?? false
        messages = c.lenientArray(.messages)
        historyLimited = c.lenient(.historyLimited) ?? false
        channelArchived = c.lenient(.channelArchived) ?? false
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
    var raw: JSONValue

    private enum CodingKeys: String, CodingKey { case threadChannelId, parentMessageId, replyCount, unreadCount, lastReplyAt, participantIds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadChannelId = c.lenient(.threadChannelId)
        parentMessageId = c.lenient(.parentMessageId)
        replyCount = c.flexibleInt(.replyCount) ?? 0
        unreadCount = c.flexibleInt(.unreadCount)
        lastReplyAt = c.lenient(.lastReplyAt)
        participantIds = c.lenient(.participantIds) ?? []
        raw = (try? JSONValue(from: decoder)) ?? .null
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

/// `GET channels/inbox`.
struct InboxPage: Sendable, Hashable, Decodable {
    var items: [InboxItem]
    var hasMore: Bool
    var totalCount: Int?
    var totalUnreadCount: Int?

    private enum CodingKeys: String, CodingKey { case items, hasMore, totalCount, totalUnreadCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lenientArray(.items)
        hasMore = c.lenient(.hasMore) ?? false
        totalCount = c.flexibleInt(.totalCount)
        totalUnreadCount = c.flexibleInt(.totalUnreadCount)
    }
}

struct InboxItem: Sendable, Hashable, Decodable {
    /// `channel`, `thread`, `dm`, ...: kept as sent.
    var kind: String
    var channelId: String
    var channelName: String?
    var channelType: String?
    var lastMessageId: String?
    var threadChannelId: String?
    var parentMessageId: String?
    var parentChannelId: String?
    var unreadCount: Int
    var hasMention: Bool
    var lastMessagePreview: String?
    var lastMessageAt: String?

    private enum CodingKeys: String, CodingKey {
        case kind, channelId, channelName, channelType, lastMessageId, threadChannelId, parentMessageId, parentChannelId
        case unreadCount, hasMention, lastMessagePreview, lastMessageAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(.kind) ?? ""
        channelId = c.lenient(.channelId) ?? ""
        channelName = c.lenient(.channelName)
        channelType = c.lenient(.channelType)
        lastMessageId = c.lenient(.lastMessageId)
        threadChannelId = c.lenient(.threadChannelId)
        parentMessageId = c.lenient(.parentMessageId)
        parentChannelId = c.lenient(.parentChannelId)
        unreadCount = c.flexibleInt(.unreadCount) ?? 0
        hasMention = c.lenient(.hasMention) ?? false
        lastMessagePreview = c.lenient(.lastMessagePreview)
        lastMessageAt = c.lenient(.lastMessageAt)
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
