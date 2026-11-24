import Foundation

/// A channel in the home list (`GET channels`).
struct Channel: Sendable, Hashable, Decodable, Identifiable {
    var id: String
    var name: String
    /// `channel`, `dm`, `thread`, ...: kept as sent.
    var type: String
    var description: String?
    var archivedAt: String?
    var joined: Bool
    var lastMessageAt: String?
    var maxReadSeq: Int64?
    var readStateVersion: Int64?
    var activityMuted: Bool
    var loungeAgentId: String?
    var serverId: String?
    /// Activity mute starts at this seq (messages before it still count).
    var muteFromSeq: Int64?
    var notificationLevel: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, description, archivedAt, joined, lastMessageAt, maxReadSeq, readStateVersion
        case activityMuted, loungeAgentId, serverId, muteFromSeq, notificationLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredId(.id)
        name = c.lenient(.name) ?? ""
        type = c.lenient(.type) ?? "channel"
        description = c.lenient(.description)
        archivedAt = c.lenient(.archivedAt)
        joined = c.lenient(.joined) ?? false
        lastMessageAt = c.lenient(.lastMessageAt)
        maxReadSeq = c.flexibleInt64(.maxReadSeq)
        readStateVersion = c.flexibleInt64(.readStateVersion)
        activityMuted = c.lenient(.activityMuted) ?? false
        loungeAgentId = c.lenient(.loungeAgentId)
        serverId = c.lenient(.serverId)
        muteFromSeq = c.flexibleInt64(.muteFromSeq)
        notificationLevel = c.lenient(.notificationLevel)
    }

    var isArchived: Bool { !(archivedAt ?? "").isEmpty }
}

/// The lounge (an agent's side conversation) attached to a DM or standing alone.
struct LoungeLink: Sendable, Hashable, Decodable {
    var channelId: String
    var joined: Bool
    var unreadCount: Int?
    var mentionCount: Int?

    private enum CodingKeys: String, CodingKey { case channelId, joined, unreadCount, mentionCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try c.requiredId(.channelId)
        joined = c.lenient(.joined) ?? false
        unreadCount = c.flexibleInt(.unreadCount)
        mentionCount = c.flexibleInt(.mentionCount)
    }
}

/// A direct-message conversation (`GET channels/dm`).
struct DirectMessageChannel: Sendable, Hashable, Decodable, Identifiable {
    var id: String
    var name: String
    var type: String
    var description: String?
    var lastMessageAt: String?
    /// `user` or `agent`.
    var peerType: String
    var peerId: String
    var peerName: String
    var peerDisplayName: String?
    var peerAvatarUrl: String?
    var maxReadSeq: Int64?
    var lastMessagePreview: String?
    var lastMessageSenderName: String?
    var lounge: LoungeLink?
    var readStateVersion: Int64?
    var activityMuted: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, type, description, lastMessageAt, peerType, peerId, peerName, peerDisplayName, peerAvatarUrl
        case maxReadSeq, lastMessagePreview, lastMessageSenderName, lounge, readStateVersion, activityMuted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredId(.id)
        name = c.lenient(.name) ?? ""
        type = c.lenient(.type) ?? "dm"
        description = c.lenient(.description)
        lastMessageAt = c.lenient(.lastMessageAt)
        peerType = c.lenient(.peerType) ?? "user"
        peerId = c.lenient(.peerId) ?? ""
        peerName = c.lenient(.peerName) ?? ""
        peerDisplayName = c.lenient(.peerDisplayName)
        peerAvatarUrl = c.lenient(.peerAvatarUrl)
        maxReadSeq = c.flexibleInt64(.maxReadSeq)
        lastMessagePreview = c.lenient(.lastMessagePreview)
        lastMessageSenderName = c.lenient(.lastMessageSenderName)
        lounge = c.lenient(.lounge)
        readStateVersion = c.flexibleInt64(.readStateVersion)
        activityMuted = c.lenient(.activityMuted) ?? false
    }

    var peerVisibleName: String {
        [peerDisplayName, peerName, name].compactMap { $0 }.first { !$0.isEmpty } ?? id
    }
}

/// A lounge with no DM to hang off (`lounges` of `GET channels/dm?include=lounges`).
struct StandaloneLounge: Sendable, Hashable, Decodable {
    var agentId: String
    var peerType: String
    var peerName: String
    var peerDisplayName: String?
    var peerAvatarUrl: String?
    var lounge: LoungeLink?

    private enum CodingKeys: String, CodingKey { case agentId, peerType, peerName, peerDisplayName, peerAvatarUrl, lounge }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.requiredId(.agentId)
        peerType = c.lenient(.peerType) ?? "agent"
        peerName = c.lenient(.peerName) ?? ""
        peerDisplayName = c.lenient(.peerDisplayName)
        peerAvatarUrl = c.lenient(.peerAvatarUrl)
        lounge = c.lenient(.lounge)
    }
}

/// `GET channels/dm?include=lounges`: older servers answer a bare array of DMs, newer ones
/// `{ dms: [...], lounges: [...] }`. Both decode here.
struct DirectMessageList: Sendable, Hashable, Decodable {
    var dms: [DirectMessageChannel]
    var lounges: [StandaloneLounge]

    init(dms: [DirectMessageChannel], lounges: [StandaloneLounge]) {
        self.dms = dms
        self.lounges = lounges
    }

    private enum CodingKeys: String, CodingKey { case dms, lounges }

    init(from decoder: Decoder) throws {
        if let bare = try? LenientArray<DirectMessageChannel>(from: decoder) {
            dms = bare.elements
            lounges = []
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dms = c.lenientArray(.dms)
        lounges = c.lenientArray(.lounges)
    }
}

/// `GET channels/unread?summary=1`.
struct UnreadSummary: Sendable, Hashable, Decodable {
    struct ChannelUnread: Sendable, Hashable, Decodable {
        var unreadCount: Int
        var hasMention: Bool
        var hasAnyMention: Bool
        var readState: JSONValue?
        var hasNew: Bool?
        var parentChannelId: String?

        private enum CodingKeys: String, CodingKey { case unreadCount, hasMention, hasAnyMention, readState, hasNew, parentChannelId }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unreadCount = c.flexibleInt(.unreadCount) ?? 0
            hasMention = c.lenient(.hasMention) ?? false
            hasAnyMention = c.lenient(.hasAnyMention) ?? hasMention
            readState = c.lenient(.readState)
            hasNew = c.lenient(.hasNew)
            parentChannelId = c.lenient(.parentChannelId)
        }
    }

    struct ThreadUnread: Sendable, Hashable, Decodable {
        var count: Int
        var hasMention: Bool

        private enum CodingKeys: String, CodingKey { case count, hasMention }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = c.flexibleInt(.count) ?? 0
            hasMention = c.lenient(.hasMention) ?? false
        }
    }

    var channels: [String: ChannelUnread]
    var threadUnread: [String: ThreadUnread]
    var stale: Bool

    private enum CodingKeys: String, CodingKey { case channels, threadUnread, stale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = c.lenientMap(.channels)
        threadUnread = c.lenientMap(.threadUnread)
        stale = c.lenient(.stale) ?? false
    }

    var totalUnread: Int { channels.values.reduce(0) { $0 + $1.unreadCount } }
}

/// A server member (`GET servers/{id}/members`).
struct ServerMember: Sendable, Hashable, Decodable, Identifiable {
    var userId: String
    var name: String
    var displayName: String?
    var email: String?
    var avatarUrl: String?
    var role: String?
    var membershipStatus: String?
    var description: String?

    var id: String { userId }

    private enum CodingKeys: String, CodingKey { case userId, id, name, displayName, email, avatarUrl, role, membershipStatus, description }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let userId = c.lenient(.userId, as: String.self) ?? c.lenient(.id, as: String.self), !userId.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.userId, .init(codingPath: c.codingPath, debugDescription: "member id"))
        }
        self.userId = userId
        name = c.lenient(.name) ?? ""
        displayName = c.lenient(.displayName)
        email = c.lenient(.email)
        avatarUrl = c.lenient(.avatarUrl)
        role = c.lenient(.role)
        membershipStatus = c.lenient(.membershipStatus)
        description = c.lenient(.description)
    }
}

extension KeyedDecodingContainer {
    /// A non-empty string id at `key`, else a decoding error (the row is unusable without it).
    func requiredId(_ key: Key) throws -> String {
        guard let value = lenient(key, as: JSONValue.self) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "required id"))
        }
        switch value {
        case .string(let text) where !text.isEmpty: return text
        case .number: if let int = value.int64Value { return String(int) }
        default: break
        }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "required id"))
    }

    /// A `{ key: T }` map; entries that do not decode are skipped.
    func lenientMap<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [String: T] {
        guard let raw = lenient(key, as: [String: JSONValue].self) else { return [:] }
        var result: [String: T] = [:]
        for (name, value) in raw {
            if let decoded = try? value.decode(T.self) { result[name] = decoded }
        }
        return result
    }
}
