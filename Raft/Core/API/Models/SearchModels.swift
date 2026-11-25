import Foundation

/// One hit of `GET messages/search` (server `services/searchService.ts` `MessageSearchResult`,
/// v1.33.1). A thread reply's `channelId` is the thread; its root conversation is `parentChannel*`.
/// `threadId` is also set on a top-level message that has a thread (the thread it opens), so it
/// does not mark a reply: `channelType == "thread"` / `parentMessageId` do.
struct MessageSearchResult: Sendable, Hashable, Decodable, Identifiable {
    var id: String
    var channelId: String
    var channelName: String?
    /// `channel`, `private`, `joint`, `dm`, `thread`, `task`.
    var channelType: String?
    var threadId: String?
    var parentMessageId: String?
    var parentChannelId: String?
    var parentChannelName: String?
    var parentChannelType: String?
    var senderId: String
    /// `user`, `agent`, `external_projection`.
    var senderType: String
    var senderName: String?
    var senderAvatarUrl: String?
    var content: String
    /// The server-cut window around the first hit ("…" on a cut side).
    var snippet: String?
    var createdAt: String?
    var retracted: Bool
    var taskId: String?
    var taskNumber: Int?
    var taskTitle: String?

    private enum CodingKeys: String, CodingKey {
        case id, channelId, channelName, channelType, threadId, parentMessageId, parentChannelId, parentChannelName, parentChannelType
        case senderId, senderType, senderName, senderAvatarUrl, content, snippet, createdAt, retracted, taskId, taskNumber, taskTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredId(.id)
        channelId = try c.requiredId(.channelId)
        channelName = c.lenient(.channelName)
        channelType = c.lenient(.channelType)
        threadId = c.lenient(.threadId)
        parentMessageId = c.lenient(.parentMessageId)
        parentChannelId = c.lenient(.parentChannelId)
        parentChannelName = c.lenient(.parentChannelName)
        parentChannelType = c.lenient(.parentChannelType)
        senderId = c.lenient(.senderId) ?? ""
        senderType = c.lenient(.senderType) ?? "user"
        senderName = c.lenient(.senderName)
        senderAvatarUrl = c.lenient(.senderAvatarUrl)
        content = c.lenient(.content) ?? ""
        snippet = c.lenient(.snippet)
        createdAt = c.lenient(.createdAt)
        retracted = c.lenient(.retracted) ?? false
        taskId = c.lenient(.taskId)
        taskNumber = c.flexibleInt(.taskNumber)
        taskTitle = c.lenient(.taskTitle)
    }

    /// A reply inside a thread.
    var isThreadReply: Bool { channelType == "thread" || (parentMessageId?.isEmpty == false) }
    var isTask: Bool { channelType == "task" }
    /// Its conversation (or the thread's root conversation) is a DM. `parentChannel*` is the
    /// message's own channel for a top-level message (`COALESCE(parent, channel)`).
    var isDirectMessage: Bool { channelType == "dm" || parentChannelType == "dm" }
}

/// A page of `GET messages/search`. `nextCursor` comes with a newest-first page (a relevance
/// search answered as `relevanceFallback`, or a timeline walk that stopped `incomplete`); the
/// next page then continues from it instead of `offset`.
struct MessageSearchPage: Sendable, Hashable, Decodable {
    var results: [MessageSearchResult]
    var hasMore: Bool
    var nextCursor: String?
    var incomplete: Bool
    /// `too_broad`: the any-word fallback was skipped (too many matches).
    var relaxedSkipped: String?
    /// `too_broad`: too many matches to rank, sorted newest first.
    var relevanceFallback: String?

    private enum CodingKeys: String, CodingKey { case results, hasMore, nextCursor, incomplete, relaxedSkipped, relevanceFallback }

    init(results: [MessageSearchResult], hasMore: Bool = false, nextCursor: String? = nil, incomplete: Bool = false, relaxedSkipped: String? = nil, relevanceFallback: String? = nil) {
        self.results = results
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.incomplete = incomplete
        self.relaxedSkipped = relaxedSkipped
        self.relevanceFallback = relevanceFallback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lenientArray(.results)
        hasMore = c.lenient(.hasMore) ?? false
        nextCursor = c.lenient(.nextCursor)
        incomplete = c.lenient(.incomplete) ?? false
        relaxedSkipped = c.lenient(.relaxedSkipped)
        relevanceFallback = c.lenient(.relevanceFallback)
    }

    /// Another page can be asked for.
    var canContinue: Bool { hasMore || (incomplete && nextCursor != nil) }
}

extension RaftAPI {
    /// `GET messages/search?q=&limit=&offset=` (or `cursor=`): no sort (the server's default is
    /// relevance) and no filters.
    func searchMessages(query: String, limit: Int = 30, offset: Int = 0, cursor: String? = nil) async throws -> MessageSearchPage {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        } else {
            items.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        return try await client.send(.get("messages/search", query: items), as: MessageSearchPage.self)
    }

    /// `POST channels/dm` with `{ agentId }` or `{ userId }`: finds or creates the DM with that peer
    /// and answers its DM row (the `GET channels/dm` row shape).
    func openDirectMessage(peerType: String, peerId: String) async throws -> DirectMessageChannel {
        let key = peerType == "agent" ? "agentId" : "userId"
        return try await client.send(.json("POST", "channels/dm", body: [key: peerId]), as: DirectMessageChannel.self)
    }
}
