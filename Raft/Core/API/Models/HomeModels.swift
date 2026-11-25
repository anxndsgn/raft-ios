import Foundation

/// One saved message (`GET channels/saved` → `{ saved, hasMore, total, globalTotal }`, server
/// `services/savedService.ts` `SavedEntry`).
struct SavedEntry: Sendable, Hashable, Decodable, Identifiable {
    var messageId: String
    var channelId: String
    var channelName: String?
    var channelType: String?
    var content: String
    var senderType: String
    var senderId: String
    var senderName: String?
    var senderAvatarUrl: String?
    var createdAt: String?
    var savedAt: String?
    var parentChannelId: String?
    var parentChannelName: String?
    var parentMessageId: String?
    /// The thread's or task's root conversation type (`dm` for a DM thread).
    var parentChannelType: String?
    /// Not sent by v1.33.1 (the web client never reads it); shown as a thumbnail when present.
    var attachments: [MessageAttachment] = []

    var id: String { messageId }

    private enum CodingKeys: String, CodingKey {
        case messageId, channelId, channelName, channelType, content, senderType, senderId, senderName, senderAvatarUrl
        case createdAt, savedAt, parentChannelId, parentChannelName, parentMessageId, parentChannelType, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.requiredId(.messageId)
        channelId = try c.requiredId(.channelId)
        channelName = c.lenient(.channelName)
        channelType = c.lenient(.channelType)
        content = c.lenient(.content) ?? ""
        senderType = c.lenient(.senderType) ?? "user"
        senderId = c.lenient(.senderId) ?? ""
        senderName = c.lenient(.senderName)
        senderAvatarUrl = c.lenient(.senderAvatarUrl)
        createdAt = c.lenient(.createdAt)
        savedAt = c.lenient(.savedAt)
        parentChannelId = c.lenient(.parentChannelId)
        parentChannelName = c.lenient(.parentChannelName)
        parentMessageId = c.lenient(.parentMessageId)
        parentChannelType = c.lenient(.parentChannelType)
        attachments = c.lenientArray(.attachments)
    }

    /// A thread reply (the web client's rule: `channelType == "thread"`, or a parent message).
    var isThreadReply: Bool { channelType == "thread" || (parentMessageId?.isEmpty == false) }
    var isTask: Bool { channelType == "task" }
    /// Its conversation (a thread's or task's root conversation) is a DM.
    var isDirectMessage: Bool {
        (isThreadReply || isTask ? (parentChannelType ?? channelType) : channelType) == "dm"
    }
}

struct SavedPage: Sendable, Hashable, Decodable {
    var saved: [SavedEntry]
    var hasMore: Bool
    /// The count for the list's subtitle and Home's chip: `globalTotal`, else `total`, else
    /// `totalCount` (v1.33.1 sends `globalTotal` and `total`).
    var total: Int
    /// Entries the page held before undecodable ones were dropped: the next page's offset step.
    var rawCount: Int

    private enum CodingKeys: String, CodingKey { case saved, hasMore, total, globalTotal, totalCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saved = c.lenientArray(.saved)
        rawCount = c.lenient(.saved, as: [JSONValue].self)?.count ?? saved.count
        hasMore = c.lenient(.hasMore) ?? false
        total = c.flexibleInt(.globalTotal) ?? c.flexibleInt(.total) ?? c.flexibleInt(.totalCount) ?? saved.count
    }
}

/// `GET servers/{id}/sidebar-order`: what the person pinned. `pinned` (`[{ kind, id }]`, kind
/// `channel | agent | human`) on newer servers, else the legacy `pinnedOrder` ids (channel ids, DM
/// channel ids or agent ids).
struct SidebarOrder: Sendable, Hashable, Decodable {
    struct PinnedRef: Sendable, Hashable, Decodable {
        var kind: String
        var id: String

        private enum CodingKeys: String, CodingKey { case kind, id }

        init(kind: String, id: String) {
            self.kind = kind
            self.id = id
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = c.lenient(.kind) ?? "channel"
            id = try c.requiredId(.id)
        }
    }

    var pinned: [PinnedRef]

    private enum CodingKeys: String, CodingKey { case pinned, pinnedOrder, pinnedChannelIds }

    init(pinned: [PinnedRef]) {
        self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let refs: [PinnedRef] = c.lenientArray(.pinned)
        if !refs.isEmpty {
            pinned = refs
        } else {
            let ids: [String] = (c.lenient(.pinnedOrder) ?? []) + (c.lenient(.pinnedChannelIds) ?? [])
            var seen = Set<String>()
            pinned = ids.filter { seen.insert($0).inserted }.map { PinnedRef(kind: "legacy", id: $0) }
        }
    }
}

/// A notification level (`docs/contracts/notifications.md` §2.2): `all`, `mentions`, `none`.
enum NotificationLevel: String, Sendable, Hashable, CaseIterable {
    case all
    case mentions
    case none
}

/// `GET notification-levels` (server scope from `X-Server-Id`): `{ serverId, server, channels, threads }`.
struct NotificationLevelSnapshot: Sendable, Hashable, Decodable {
    var serverId: String?
    var server: NotificationLevel?

    private enum CodingKeys: String, CodingKey { case serverId, server }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverId = c.lenient(.serverId)
        server = c.lenient(.server, as: String.self).flatMap(NotificationLevel.init(rawValue:))
    }
}

extension RaftAPI {
    /// `GET channels/saved?limit&offset`.
    func saved(limit: Int = 30, offset: Int = 0) async throws -> SavedPage {
        try await client.send(
            .get("channels/saved", query: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]),
            as: SavedPage.self
        )
    }

    func sidebarOrder(serverId: String) async throws -> SidebarOrder {
        try await client.send(.get("servers/\(Self.segment(serverId))/sidebar-order", serverScope: .explicit(serverId)), as: SidebarOrder.self)
    }

    func notificationLevels() async throws -> NotificationLevelSnapshot {
        try await client.send(.get("notification-levels"), as: NotificationLevelSnapshot.self)
    }

    /// `PUT notification-levels { scope: "server", id, level }`.
    func setServerNotificationLevel(serverId: String, level: NotificationLevel) async throws {
        try await client.send(.json("PUT", "notification-levels", body: ["scope": "server", "id": serverId, "level": level.rawValue]))
    }

    /// `PUT notification-levels { scope: "channel", id, level }` (Activity's Mute).
    func setChannelNotificationLevel(channelId: String, level: NotificationLevel) async throws {
        try await client.send(.json("PUT", "notification-levels", body: ["scope": "channel", "id": channelId, "level": level.rawValue]))
    }

    /// `POST channels/{id}/unread`: the conversation marked unread again.
    func markChannelUnread(channelId: String) async throws {
        try await client.send(.json("POST", "channels/\(Self.segment(channelId))/unread", body: [String: String]()))
    }

    /// `GET auth/second-factor/status` → `enabled`.
    func secondFactorEnabled() async throws -> Bool {
        let response = try await client.send(.get("auth/second-factor/status", serverScope: .none))
        return JSONValue.parse(response.data)?.objectValue?["enabled"]?.boolValue ?? false
    }

    /// `POST channels/{id}/read-all`: the conversation (and its threads) read for this person.
    func markChannelReadAll(channelId: String) async throws {
        try await client.send(.json("POST", "channels/\(Self.segment(channelId))/read-all", body: [String: String]()))
    }

    /// `POST channels/inbox/read-all`: every Activity row read.
    func markInboxReadAll() async throws {
        try await client.send(.json("POST", "channels/inbox/read-all", body: [String: String]()))
    }

    /// `POST channels/threads/follow|unfollow { parentMessageId }`.
    func setThreadFollow(parentMessageId: String, follow: Bool) async throws {
        try await client.send(.json("POST", follow ? "channels/threads/follow" : "channels/threads/unfollow", body: ["parentMessageId": parentMessageId]))
    }
}
