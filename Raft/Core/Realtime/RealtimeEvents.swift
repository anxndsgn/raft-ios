import Foundation

/// Socket event names, mirrored from the old app's generated realtime contract
/// (`GeneratedRealtimeContract.swift`, from slock `packages/shared`).
enum SocketEventName {
    // Client lifecycle and sync
    static let roomsJoined = "rooms:joined"
    /// The server's first member-room lookup failed; it keeps retrying and sends `rooms:joined`
    /// when it succeeds. Until then channel `message:new` frames do not arrive.
    static let roomsJoinFailed = "rooms:join_failed"
    static let channelJoined = "channel:joined"
    static let channelJoinDenied = "channel:join_denied"
    static let syncResume = "sync:resume"
    static let syncHorizon = "sync:horizon"
    static let syncResumeResponse = "sync:resume:response"
    static let joinChannel = "join:channel"
    static let leaveChannel = "leave:channel"
    static let heartbeat = "heartbeat"
    static let presenceActivity = "presence:activity"

    // Server → client
    static let messageNew = "message:new"
    static let messageUpdated = "message:updated"
    static let directMessageNew = "dm:new"
    static let threadUpdated = "thread:updated"
    static let channelUpdated = "channel:updated"
    static let channelMembersUpdated = "channel:members-updated"
    static let scopeReadUpdated = "scope_read:updated"
    static let taskCreated = "task:created"
    static let taskUpdated = "task:updated"
    static let taskDeleted = "task:deleted"
    static let agentActivity = "agent:activity"
    static let agentActivityState = "agent:activity_state"
    static let agentActivitySubscribe = "agent:activity:subscribe"
    static let agentActivityUnsubscribe = "agent:activity:unsubscribe"
    static let agentActivitySubscribed = "agent:activity:subscribed"
    static let agentSeen = "agent:seen"
    static let agentTyping = "agent:typing"
    static let agentSession = "agent:session"
    static let agentCreated = "agent:created"
    static let agentUpdated = "agent:updated"
    static let agentDeleted = "agent:deleted"
    static let machineStatus = "machine:status"
    static let machineCapabilities = "machine:capabilities"
    static let machineUpdated = "machine:updated"
    static let computerUpgradeProgress = "computer:upgrade:progress"
    static let computerUpgradeDone = "computer:upgrade:done"
    static let machineUpgradeRequest = "machine:upgrade-request"
    static let computerRestartDone = "computer:restart:done"
    static let machineRuntimeAuthUpdated = "machine:runtime_auth:updated"
    static let runtimeAuthLoginEvent = "runtime_auth:login:event"
    static let runtimeAuthLoginResult = "runtime_auth:login:result"
    static let daemonStatus = "daemon:status"
    static let serverMemberAdded = "server:member-added"
    static let serverMemberUpdated = "server:member-updated"
    static let serverMemberLeft = "server:member:left"
    static let serverMemberRemoved = "server:member-removed"
    static let serverMembershipRemoved = "server:membership-removed"
    static let serverDeleted = "server:deleted"
    static let serverPlanUpdated = "server:plan-updated"
    static let serverFeaturesChanged = "server:features-changed"
    static let appearanceUpdated = "appearance:updated"
    static let userProfileUpdated = "user:profile-updated"
    static let productFeedbackUnread = "product_feedback:unread"
    static let productFeedbackAppUnread = "product_feedback:app_unread"
    static let activityChanged = "activity:changed"
    static let announcementNew = "announcement:new"
    static let reminderFired = "reminder:fired"
    static let reminderScheduled = "reminder:scheduled"
    static let reminderCanceled = "reminder:canceled"
    static let threadFollowersUpdated = "thread:followers-updated"
    static let threadReplyUpdated = "thread:reply_updated"
    static let readStateUpdated = "read_state:updated"
    static let readStateUpdatedBulk = "read_state:updated_bulk"
    static let notificationPrefsUpdated = "notification_prefs:updated"
    static let pinnedUpdated = "pinned:updated"
    static let notificationPush = "notification:push"
    static let notificationRetract = "notification:retract"
    static let jointInvitesChanged = "joint-invites:changed"
    static let permissionUpdatesChanged = "permission-updates:changed"
    static let linkCardOperationChanged = "link_card.operation_changed"
    static let linkCardChanged = "link_card.changed"
    static let actorUpdated = "actor:updated"
    static let messageDisplayPrefsUpdated = "message_display_prefs:updated"
    /// `{ serverId? }`: the `sync/changes` log moved (the app does not use that log yet).
    static let syncChanged = "sync:changed"
    /// To the reactor's user room after a reaction (viewer-scoped reaction state).
    static let reactionViewerUpdated = "reaction_viewer:updated"

    /// Events the server is known to send. Anything else is delivered as `.other` and counted.
    static let serverWireEvents: Set<String> = [
        roomsJoined, channelJoined, channelJoinDenied, syncResumeResponse, heartbeat,
        messageNew, messageUpdated, directMessageNew, threadUpdated, channelUpdated, channelMembersUpdated,
        scopeReadUpdated, taskCreated, taskUpdated, taskDeleted, agentActivity, agentActivityState,
        agentActivitySubscribed, agentSeen, agentTyping, agentSession, agentCreated, agentUpdated, agentDeleted,
        machineStatus, machineCapabilities, machineUpdated, computerUpgradeProgress, computerUpgradeDone,
        machineUpgradeRequest, computerRestartDone, machineRuntimeAuthUpdated, runtimeAuthLoginEvent,
        runtimeAuthLoginResult, daemonStatus, serverMemberAdded, serverMemberUpdated, serverMemberLeft,
        serverMemberRemoved, serverMembershipRemoved, serverDeleted, serverPlanUpdated, serverFeaturesChanged,
        appearanceUpdated, userProfileUpdated, productFeedbackUnread, productFeedbackAppUnread, activityChanged,
        announcementNew, reminderFired, reminderScheduled, reminderCanceled, threadFollowersUpdated,
        threadReplyUpdated, readStateUpdated, readStateUpdatedBulk, notificationPrefsUpdated, pinnedUpdated,
        notificationPush, notificationRetract, jointInvitesChanged, permissionUpdatesChanged,
        linkCardOperationChanged, linkCardChanged, actorUpdated, messageDisplayPrefsUpdated,
        roomsJoinFailed, syncChanged, reactionViewerUpdated,
    ]
}

/// A refused Socket.IO CONNECT (`44{ message, data? }`), from the server's handshake errors.
enum SocketHandshakeError: Sendable, Equatable {
    /// Terminal until something changes (membership): do not retry on a timer.
    case notMember
    /// Terminal: the server requires SSO for this person.
    case ssoRequired
    /// The token was refused: refresh it, then reconnect.
    case authRejected(String)
    /// Anything else: back off and retry.
    case other(String)

    static func classify(_ data: JSONValue?) -> SocketHandshakeError {
        let message = data?["message"]?.stringValue ?? data?.stringValue ?? ""
        let code = data?["data"]?["code"]?.stringValue ?? data?["code"]?.stringValue ?? ""
        if message == "Not a member of this server" { return .notMember }
        if message == "SSO_REQUIRED" || code == "SSO_REQUIRED" { return .ssoRequired }
        let authMessages: Set<String> = [
            "Authentication required",
            "Invalid token type",
            "Invalid or expired token",
            "Authentication changed; reconnect required",
        ]
        if authMessages.contains(message) { return .authRejected(message) }
        return .other(message.isEmpty ? "connect_error" : message)
    }

    var isTerminal: Bool {
        switch self {
        case .notMember, .ssoRequired: true
        default: false
        }
    }
}

/// `sync:resume:response`.
struct SyncResumeResponse: Sendable, Hashable, Decodable {
    var messages: [Message]
    var currentSeq: Int64
    var hasMore: Bool
    /// Decimal xid8 text (never a number); nil from older servers.
    var horizon: String?
    var horizonReset: Bool

    private enum CodingKeys: String, CodingKey { case messages, currentSeq, hasMore, horizon, horizonReset }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.lenientArray(.messages)
        currentSeq = c.flexibleInt64(.currentSeq) ?? 0
        hasMore = c.lenient(.hasMore) ?? false
        horizon = c.lenient(.horizon, as: String.self) ?? c.flexibleInt64(.horizon).map(String.init)
        horizonReset = c.lenient(.horizonReset) ?? false
    }
}

/// `read_state:updated` (one scope) and the entries of `read_state:updated_bulk`.
struct ReadStateUpdate: Sendable, Hashable, Decodable {
    var serverId: String?
    var scopeId: String
    var maxReadSeq: Int64?
    var readStateVersion: Int64?
    var unreadCount: Int?
    var markedUnread: Bool?

    private enum CodingKeys: String, CodingKey { case serverId, scopeId, maxReadSeq, readStateVersion, unreadCount, markedUnread }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverId = c.lenient(.serverId)
        scopeId = try c.requiredId(.scopeId)
        maxReadSeq = c.flexibleInt64(.maxReadSeq)
        readStateVersion = c.flexibleInt64(.readStateVersion)
        unreadCount = c.flexibleInt(.unreadCount)
        markedUnread = c.lenient(.markedUnread)
    }
}

/// `thread:updated` (web `socketBridge.ts` `threadUpdated`): `{ parentMessageId, threadChannelId,
/// replyCount, lastReplyAt, participantIds, unreadCount?, firstUnreadMessageId?, latestReply? }`.
/// It names no parent channel: a holder finds the parent by `parentMessageId`. `latestReply` is the
/// newest reply (a full message) — the only copy a client gets of a reply when it has not joined the
/// thread's room.
struct ThreadUpdate: Sendable, Hashable, Decodable {
    var parentMessageId: String
    var threadChannelId: String?
    var channelId: String?
    var replyCount: Int
    var lastReplyAt: String?
    var unreadCount: Int?
    var participantIds: [String]
    var firstUnreadMessageId: String?
    var latestReply: Message?

    private enum CodingKeys: String, CodingKey {
        case parentMessageId, threadChannelId, channelId, replyCount, lastReplyAt, unreadCount, participantIds
        case firstUnreadMessageId, latestReply
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parentMessageId = try c.requiredId(.parentMessageId)
        threadChannelId = c.lenient(.threadChannelId)
        channelId = c.lenient(.channelId)
        replyCount = c.flexibleInt(.replyCount) ?? 0
        lastReplyAt = c.lenient(.lastReplyAt)
        unreadCount = c.flexibleInt(.unreadCount)
        participantIds = c.lenient(.participantIds) ?? []
        firstUnreadMessageId = c.lenient(.firstUnreadMessageId)
        latestReply = c.lenient(.latestReply)
    }
}

/// `agent:typing` (shared `agentTyping.ts`): an agent is about to post into `channelId` (a thread
/// reply when `parentMessageId` is set). One entry per tool call; `end` or `expiresAt` (server
/// epoch ms, at most `ttl` ahead) removes it, as does the agent's message landing there.
/// There is no human typing event in the server.
struct AgentTyping: Sendable, Hashable, Decodable {
    static let ttl: Double = 20

    var agentId: String
    var serverId: String
    var channelId: String
    var parentMessageId: String?
    var callId: String
    var isStart: Bool
    var expiresAtMs: Double

    private enum CodingKeys: String, CodingKey { case agentId, serverId, channelId, parentMessageId, callId, state, expiresAt }

    init(agentId: String, serverId: String, channelId: String, parentMessageId: String? = nil, callId: String, isStart: Bool, expiresAtMs: Double = 0) {
        self.agentId = agentId
        self.serverId = serverId
        self.channelId = channelId
        self.parentMessageId = parentMessageId
        self.callId = callId
        self.isStart = isStart
        self.expiresAtMs = expiresAtMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.requiredId(.agentId)
        serverId = try c.requiredId(.serverId)
        channelId = try c.requiredId(.channelId)
        callId = try c.requiredId(.callId)
        parentMessageId = c.lenient(.parentMessageId)
        switch c.lenient(.state, as: String.self) {
        case "start": isStart = true
        case "end": isStart = false
        default:
            throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "state is start or end")
        }
        expiresAtMs = c.lenient(.expiresAt) ?? 0
    }

    /// Local deadline: the server's `expiresAt` when it is within (0, ttl] of `now`, else now + ttl
    /// (a skewed clock must neither drop the line at once nor keep it far too long).
    func deadline(now: Date) -> Date {
        let remaining = expiresAtMs / 1000 - now.timeIntervalSince1970
        return now.addingTimeInterval(remaining > 0 && remaining <= Self.ttl ? remaining : Self.ttl)
    }
}

/// A server event, typed where the app uses it. Everything else (and anything that fails to
/// decode) arrives as `.other` with its raw arguments.
enum RealtimeEvent: Sendable, Hashable {
    case roomsJoined
    case roomsJoinFailed
    case messageNew(Message)
    case messageUpdated(Message)
    case syncResume(SyncResumeResponse)
    case heartbeat(seq: Int64?)
    case channelJoined(channelId: String)
    case channelJoinDenied(channelId: String)
    case directMessageNew(channelId: String)
    case readStateUpdated(ReadStateUpdate)
    case readStateUpdatedBulk([ReadStateUpdate])
    case threadUpdated(ThreadUpdate)
    /// A thread reply's new copy (a bare message), like `message:updated` for replies.
    case threadReplyUpdated(Message)
    case agentTyping(AgentTyping)
    case threadFollowersUpdated(threadChannelId: String)
    case channelUpdated(channelId: String?, raw: JSONValue)
    case channelMembersUpdated(channelId: String?)
    case activityChanged(serverId: String?, source: String?)
    case serverMembership(name: String, serverId: String?, userId: String?)
    case other(name: String, args: [JSONValue])

    var name: String {
        switch self {
        case .roomsJoined: SocketEventName.roomsJoined
        case .roomsJoinFailed: SocketEventName.roomsJoinFailed
        case .messageNew: SocketEventName.messageNew
        case .messageUpdated: SocketEventName.messageUpdated
        case .syncResume: SocketEventName.syncResumeResponse
        case .heartbeat: SocketEventName.heartbeat
        case .channelJoined: SocketEventName.channelJoined
        case .channelJoinDenied: SocketEventName.channelJoinDenied
        case .directMessageNew: SocketEventName.directMessageNew
        case .readStateUpdated: SocketEventName.readStateUpdated
        case .readStateUpdatedBulk: SocketEventName.readStateUpdatedBulk
        case .threadUpdated: SocketEventName.threadUpdated
        case .threadReplyUpdated: SocketEventName.threadReplyUpdated
        case .agentTyping: SocketEventName.agentTyping
        case .threadFollowersUpdated: SocketEventName.threadFollowersUpdated
        case .channelUpdated: SocketEventName.channelUpdated
        case .channelMembersUpdated: SocketEventName.channelMembersUpdated
        case .activityChanged: SocketEventName.activityChanged
        case .serverMembership(let name, _, _): name
        case .other(let name, _): name
        }
    }

    /// Types an incoming event. Payloads are the first argument.
    static func decode(name: String, args: [JSONValue]) -> RealtimeEvent {
        let payload = args.first ?? .null
        func message() -> Message? {
            // `{ message }` or the bare message.
            if let inner = payload["message"], let decoded = try? inner.decode(Message.self) { return decoded }
            return try? payload.decode(Message.self)
        }
        func id(_ keys: String...) -> String? {
            for key in keys { if let value = payload[key]?.stringValue, !value.isEmpty { return value } }
            return payload.stringValue
        }
        switch name {
        case SocketEventName.roomsJoined:
            return .roomsJoined
        case SocketEventName.roomsJoinFailed:
            return .roomsJoinFailed
        case SocketEventName.threadReplyUpdated:
            if let message = message() { return .threadReplyUpdated(message) }
        case SocketEventName.agentTyping:
            if let typing = try? payload.decode(AgentTyping.self) { return .agentTyping(typing) }
        case SocketEventName.messageNew:
            if let message = message() { return .messageNew(message) }
        case SocketEventName.messageUpdated:
            if let message = message() { return .messageUpdated(message) }
        case SocketEventName.syncResumeResponse:
            if let response = try? payload.decode(SyncResumeResponse.self) { return .syncResume(response) }
        case SocketEventName.heartbeat:
            return .heartbeat(seq: payload["seq"]?.int64Value)
        case SocketEventName.channelJoined:
            if let channelId = id("channelId") { return .channelJoined(channelId: channelId) }
        case SocketEventName.channelJoinDenied:
            if let channelId = id("channelId") { return .channelJoinDenied(channelId: channelId) }
        case SocketEventName.directMessageNew:
            if let channelId = id("channelId") { return .directMessageNew(channelId: channelId) }
        case SocketEventName.readStateUpdated:
            if let update = try? payload.decode(ReadStateUpdate.self) { return .readStateUpdated(update) }
        case SocketEventName.readStateUpdatedBulk:
            if let scopes = payload["scopes"]?.arrayValue {
                return .readStateUpdatedBulk(scopes.compactMap { try? $0.decode(ReadStateUpdate.self) })
            }
        case SocketEventName.threadUpdated:
            if let update = try? payload.decode(ThreadUpdate.self) { return .threadUpdated(update) }
        case SocketEventName.threadFollowersUpdated:
            if let threadChannelId = id("threadChannelId") { return .threadFollowersUpdated(threadChannelId: threadChannelId) }
        case SocketEventName.channelUpdated:
            return .channelUpdated(channelId: payload["channel"]?["id"]?.stringValue ?? payload["channelId"]?.stringValue, raw: payload)
        case SocketEventName.channelMembersUpdated:
            return .channelMembersUpdated(channelId: payload["channelId"]?.stringValue ?? payload["id"]?.stringValue)
        case SocketEventName.activityChanged:
            return .activityChanged(serverId: payload["serverId"]?.stringValue, source: payload["source"]?.stringValue)
        case SocketEventName.serverMemberAdded, SocketEventName.serverMemberUpdated, SocketEventName.serverMemberLeft,
             SocketEventName.serverMemberRemoved, SocketEventName.serverMembershipRemoved, SocketEventName.serverDeleted:
            return .serverMembership(name: name, serverId: payload["serverId"]?.stringValue, userId: payload["userId"]?.stringValue)
        default:
            break
        }
        return .other(name: name, args: args)
    }
}
