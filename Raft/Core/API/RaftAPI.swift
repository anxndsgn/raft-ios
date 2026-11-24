import Foundation

/// Typed calls for the routes the app uses. Every call goes through `RaftHTTPClient` (headers,
/// selected server, overload retry, token refresh).
struct RaftAPI: Sendable {
    let client: RaftHTTPClient

    // MARK: Meta

    /// `GET version` (unauthenticated). Raw JSON: the shape is not modelled.
    func version() async throws -> JSONValue {
        var request = APIRequest.get("version", serverScope: .none)
        request.authenticated = false
        let response = try await client.send(request)
        return JSONValue.parse(response.data) ?? .null
    }

    // MARK: Channels

    func channels() async throws -> [Channel] {
        let response = try await client.send(.get("channels"))
        return try ListEnvelope<Channel>.decode(response.data, keys: ["channels", "items"], path: "channels", traceId: response.traceId)
    }

    /// `GET channels/{id}`: one channel row (bare), as the list sends it.
    func channel(id: String) async throws -> Channel {
        try await client.send(.get("channels/\(Self.segment(id))"), as: Channel.self)
    }

    /// `GET channels/dm`. Server v1.33.1 answers a bare array of DM rows (`id, name, type, description,
    /// createdAt, peerType (agent | user), peerId, peerName, peerDisplayName, peerDescription,
    /// peerAvatarUrl, lastMessageAt/Preview/SenderName, maxReadSeq, readStateVersion, activityMuted,
    /// notification level, lounge?` — an agent's lounge rides on its DM row), agent DMs first, then by
    /// last message. `include=lounges` and the `{ dms, lounges }` envelope come from the old app (newer
    /// servers); both shapes decode.
    func directMessages(includeLounges: Bool = true) async throws -> DirectMessageList {
        let query = includeLounges ? [URLQueryItem(name: "include", value: "lounges")] : []
        return try await client.send(.get("channels/dm", query: query), as: DirectMessageList.self)
    }

    func unreadSummary() async throws -> UnreadSummary {
        try await client.send(.get("channels/unread", query: [URLQueryItem(name: "summary", value: "1")]), as: UnreadSummary.self)
    }

    /// `POST channels/{id}/read { seq }`: read up to `seq`.
    func markRead(channelId: String, seq: Int64) async throws {
        struct Body: Encodable { let seq: Int64 }
        try await client.send(.json("POST", "channels/\(Self.segment(channelId))/read", body: Body(seq: seq)))
    }

    func inbox(filter: String? = nil, limit: Int = 30, offset: Int = 0) async throws -> InboxPage {
        var query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let filter { query.insert(URLQueryItem(name: "filter", value: filter), at: 0) }
        return try await client.send(.get("channels/inbox", query: query), as: InboxPage.self)
    }

    // MARK: Messages

    /// `GET messages/channel/{id}`: newest `limit`, or older than `before` / newer than `after` (seqs).
    func messages(channelId: String, limit: Int = 50, before: Int64? = nil, after: Int64? = nil) async throws -> MessagePage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        let request = APIRequest.get("messages/channel/\(Self.segment(channelId))", query: query)
        let response = try await client.send(request)
        var page: MessagePage
        do {
            page = try RaftJSON.decode(MessagePage.self, from: response.data)
        } catch {
            throw APIError.decoding(path: request.path, detail: RaftHTTPClient.describe(error), traceId: response.traceId)
        }
        if before == nil, after == nil, let horizon = response.headers["x-sync-horizon"], !horizon.isEmpty {
            page.syncHorizon = horizon
        }
        return page
    }

    func messageContext(messageId: String, channelId: String) async throws -> MessageContextPage {
        try await client.send(
            .get("messages/context/\(Self.segment(messageId))", query: [URLQueryItem(name: "channelId", value: channelId)]),
            as: MessageContextPage.self
        )
    }

    /// `GET messages/sync?since_seq=&limit=&channel_id=`: messages after a server-wide seq (bare array).
    func syncMessages(sinceSeq: Int64, limit: Int = 200, channelId: String? = nil) async throws -> [Message] {
        var query = [URLQueryItem(name: "since_seq", value: String(sinceSeq)), URLQueryItem(name: "limit", value: String(limit))]
        if let channelId { query.append(URLQueryItem(name: "channel_id", value: channelId)) }
        let response = try await client.send(.get("messages/sync", query: query))
        return try ListEnvelope<Message>.decode(response.data, keys: ["messages"], path: "messages/sync", traceId: response.traceId)
    }

    func sendMessage(_ body: SendMessageBody) async throws -> SendMessageResult {
        try await client.send(.json("POST", "v2/messages", body: body), as: SendMessageResult.self)
    }

    /// `POST channels/dm` with `{ userId }`: finds or creates the DM with a person (a self-DM
    /// when it is the caller's own id).
    func openDirectMessage(userId: String) async throws {
        try await client.send(.json("POST", "channels/dm", body: ["userId": userId]))
    }

    func addReaction(messageId: String, emoji: String) async throws {
        try await client.send(.json("POST", "messages/\(Self.segment(messageId))/reactions", body: ["emoji": emoji]))
    }

    func removeReaction(messageId: String, emoji: String) async throws {
        try await client.send(.json("DELETE", "messages/\(Self.segment(messageId))/reactions", body: ["emoji": emoji]))
    }

    // MARK: Threads

    /// `GET channels/{id}/threads?parentMessageIds=a,b`: summaries keyed by parent message id.
    func threadSummaries(channelId: String, parentMessageIds: [String], limit: Int? = nil) async throws -> [String: ThreadSummary] {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if !parentMessageIds.isEmpty {
            query.append(URLQueryItem(name: "parentMessageIds", value: parentMessageIds.joined(separator: ",")))
        }
        let response = try await client.send(.get("channels/\(Self.segment(channelId))/threads", query: query))
        guard let object = JSONValue.parse(response.data)?.objectValue else {
            throw APIError.decoding(path: "channels/{id}/threads", detail: "expected an object", traceId: response.traceId)
        }
        // Either the record itself or `{ threads: { ... } }`.
        let record = object["threads"]?.objectValue ?? object
        var result: [String: ThreadSummary] = [:]
        for (parentId, value) in record {
            if let summary = try? value.decode(ThreadSummary.self) { result[parentId] = summary }
        }
        return result
    }

    func createThread(channelId: String, parentMessageId: String) async throws -> CreateThreadResult {
        try await client.send(
            .json("POST", "channels/\(Self.segment(channelId))/threads", body: ["parentMessageId": parentMessageId]),
            as: CreateThreadResult.self
        )
    }

    // MARK: Attachments

    /// `POST attachments/upload` (multipart: `channelId` + one `files` part per file).
    func uploadAttachments(channelId: String, files: [UploadFile]) async throws -> [UploadedAttachment] {
        var form = MultipartForm()
        form.addField("channelId", channelId)
        for file in files { form.addFile("files", filename: file.filename, mimeType: file.mimeType, data: file.data) }
        var request = APIRequest(method: "POST", path: "attachments/upload", body: form.finish(), contentType: form.contentType)
        request.timeout = 120
        let response = try await client.send(request)
        return try ListEnvelope<UploadedAttachment>.decode(response.data, keys: ["attachments"], path: "attachments/upload", traceId: response.traceId)
    }

    func attachmentURLs(ids: [String]) async throws -> [AttachmentURL] {
        let response = try await client.send(.json("POST", "attachments/urls", body: ["attachmentIds": ids]))
        return try ListEnvelope<AttachmentURL>.decode(response.data, keys: ["urls"], path: "attachments/urls", traceId: response.traceId)
    }

    func attachmentURL(id: String) async throws -> AttachmentURL {
        try await client.send(.get("attachments/\(Self.segment(id))/url"), as: AttachmentURL.self)
    }

    // MARK: Members

    func members(serverId: String) async throws -> [ServerMember] {
        let response = try await client.send(.get("servers/\(Self.segment(serverId))/members", serverScope: .explicit(serverId)))
        return try ListEnvelope<ServerMember>.decode(response.data, keys: ["members", "items", "results"], path: "servers/{id}/members", traceId: response.traceId)
    }

    /// `GET agents`: the server's agents (bare array) with avatar, runtime and live activity.
    func agents() async throws -> [AgentProfile] {
        let response = try await client.send(.get("agents"))
        return try ListEnvelope<AgentProfile>.decode(response.data, keys: ["agents", "items"], path: "agents", traceId: response.traceId)
    }

    /// A path segment with `/`, `?`, `#` and `%` escaped.
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// `multipart/form-data` body builder.
struct MultipartForm: Sendable {
    let boundary: String
    private var body = Data()

    init(boundary: String = "raft-\(RandomHex.string(bytes: 12))") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.quoted(name))\"; filename=\"\(Self.quoted(filename))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func finish() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ text: String) {
        body.append(Data(text.utf8))
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
