import Foundation
import Testing
@testable import Raft

struct ModelDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try RaftJSON.decode(T.self, from: Data(json.utf8))
    }

    @Test func directMessagesDecodeBareArray() throws {
        let list = try decode(DirectMessageList.self, #"""
        [{"id":"d1","name":"dm","type":"dm","peerType":"user","peerId":"u2","peerName":"sam","maxReadSeq":"7",
          "lounge":{"channelId":"l1","joined":true,"unreadCount":2}},
         {"name":"no id"}]
        """#)
        #expect(list.dms.map(\.id) == ["d1"], "a row without an id is skipped")
        #expect(list.dms.first?.maxReadSeq == 7)
        #expect(list.dms.first?.lounge?.unreadCount == 2)
        #expect(list.lounges.isEmpty)
    }

    @Test func directMessagesDecodeWrappedWithLounges() throws {
        let list = try decode(DirectMessageList.self, #"""
        {"dms":[{"id":"d1","peerType":"agent","peerId":"a1","peerName":"bot","peerDisplayName":"Bot"}],
         "lounges":[{"agentId":"a2","peerType":"agent","peerName":"helper","lounge":{"channelId":"l2","joined":false}}]}
        """#)
        #expect(list.dms.first?.peerVisibleName == "Bot")
        #expect(list.lounges.map(\.agentId) == ["a2"])
        #expect(list.lounges.first?.lounge?.joined == false)
    }

    @Test func directMessagesEndpointAcceptsBothShapes() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels/dm", replies: [
            .json(200, #"[{"id":"d1"}]"#),
            .json(200, #"{"dms":[{"id":"d2"}],"lounges":[]}"#),
        ])
        #expect(try await core.api.directMessages().dms.map(\.id) == ["d1"])
        #expect(try await core.api.directMessages().dms.map(\.id) == ["d2"])
        #expect(core.server.requests.first?.query["include"] == "lounges")
    }

    @Test func unreadSummaryDecodes() throws {
        let summary = try decode(UnreadSummary.self, #"""
        {"channels":{"c1":{"unreadCount":3,"hasMention":true},"c2":{"unreadCount":"2","hasMention":false,"parentChannelId":"c1"},"bad":5},
         "threadUnread":{"t1":{"count":1,"hasMention":false}},"stale":true}
        """#)
        #expect(summary.channels.count == 2)
        #expect(summary.channels["c1"]?.hasAnyMention == true)
        #expect(summary.totalUnread == 5)
        #expect(summary.threadUnread["t1"]?.count == 1)
        #expect(summary.stale)
    }

    @Test func messagesDecodeTolerantly() throws {
        let page = try decode(MessagePage.self, #"""
        {"messages":[
          {"id":"m1","seq":"10","channelId":"c1","senderType":"user","senderId":"u1","senderName":"Sam","content":"hi",
           "attachments":[{"id":"a1","filename":"x.png","mimeType":"image/png","sizeBytes":"2048","width":10},{"broken":true}],
           "reactions":[{"emoji":"👍","count":2,"reactorIds":["u1","u2"],"reactorNames":["Sam","Al"]}],
           "mentions":[{"type":"user","id":"u2","name":"Al"}],
           "threadSummary":{"threadChannelId":"t1","replyCount":4,"unreadCount":1},
           "conversationContext":{"channelType":"channel"},"actionMetadata":{"k":"v"},"commentRef":null,"unknownField":[1,2]},
          {"id":42,"content":null},
          {"content":"no id"}
        ],"historyLimited":true,"threadSummariesByParentMessageId":{"m1":{"threadChannelId":"t1","replyCount":4}}}
        """#)
        #expect(page.messages.map(\.id) == ["m1", "42"])
        let first = try #require(page.messages.first)
        #expect(first.seq == 10)
        #expect(first.attachments.count == 1)
        #expect(first.attachments.first?.sizeBytes == 2048)
        #expect(first.attachments.first?.isImage == true)
        #expect(first.reactions.first?.count == 2)
        #expect(first.mentions.first?.name == "Al")
        #expect(first.threadSummary?.replyCount == 4)
        #expect(first.actionMetadata == ["k": "v"])
        #expect(first.commentRef == nil)
        #expect(page.messages[1].content == "")
        #expect(page.historyLimited)
        #expect(page.threadSummariesByParentMessageId["m1"]?.replyCount == 4)
    }

    @Test func sendBodyOmitsRandomIdWhenNil() throws {
        let plain = try #require(JSONValue.parse(try RaftJSON.encode(SendMessageBody(channelId: "c1", content: "hi"))))
        #expect(plain == ["channelId": "c1", "content": "hi", "attachmentIds": [], "asTask": false])
        #expect(plain["randomId"] == nil)
        #expect(plain["mentions"] == nil)
        let full = try #require(JSONValue.parse(try RaftJSON.encode(SendMessageBody(
            channelId: "c1", content: "hi @Al", attachmentIds: ["a1"], asTask: true, randomId: "r-1",
            mentions: [MessageMention(type: "user", id: "u2", name: "Al")]
        ))))
        #expect(full["randomId"] == "r-1")
        #expect(full["mentions"] == [["type": "user", "id": "u2", "name": "Al"]])
        #expect(full["asTask"] == true)
    }

    @Test func sendAnswerDecodesBothShapes() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST v2/messages", replies: [
            .json(200, #"{"message":{"id":"m1","content":"hi"},"unresolvedMentionHandles":["@nobody"]}"#),
            .json(200, #"{"id":"m2","content":"hi"}"#),
        ])
        let wrapped = try await core.api.sendMessage(SendMessageBody(channelId: "c1", content: "hi"))
        #expect(wrapped.message.id == "m1")
        #expect(wrapped.unresolvedMentionHandles == ["@nobody"])
        let bare = try await core.api.sendMessage(SendMessageBody(channelId: "c1", content: "hi"))
        #expect(bare.message.id == "m2")
        #expect(core.server.requests.first?.json?["randomId"] == nil)
    }

    @Test func pagingContextAndSyncQueries() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, #"{"messages":[],"historyLimited":false}"#))
        core.server.on("GET messages/context/m1", .json(200, #"{"channelId":"c1","targetMessageId":"m1","hasOlder":true,"hasNewer":false,"messages":[{"id":"m1"}]}"#))
        core.server.on("GET messages/sync", .json(200, #"[{"id":"m5","seq":5}]"#))
        _ = try await core.api.messages(channelId: "c1", limit: 20, before: 100)
        let context = try await core.api.messageContext(messageId: "m1", channelId: "c1")
        let synced = try await core.api.syncMessages(sinceSeq: 4, channelId: "c1")
        #expect(context.hasOlder)
        #expect(synced.first?.seq == 5)
        let requests = core.server.requests
        #expect(requests[0].query == ["limit": "20", "before": "100"])
        #expect(requests[1].query == ["channelId": "c1"])
        #expect(requests[2].query == ["since_seq": "4", "limit": "200", "channel_id": "c1"])
    }

    @Test func reactionsReadThreadsAndInbox() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST messages/m1/reactions", .json(200, "{}"))
        core.server.on("DELETE messages/m1/reactions", .json(200, "{}"))
        core.server.on("POST channels/c1/read", .json(200, "{}"))
        core.server.on("GET channels/c1/threads", .json(200, #"{"m1":{"threadChannelId":"t1","replyCount":"3"},"m2":"junk"}"#))
        core.server.on("POST channels/c1/threads", .json(200, #"{"threadChannelId":"t9","created":true}"#))
        core.server.on("GET channels/inbox", .json(200, #"{"items":[{"kind":"thread","channelId":"c1","threadChannelId":"t1","unreadCount":2,"hasMention":true}],"hasMore":true,"totalCount":9}"#))
        try await core.api.addReaction(messageId: "m1", emoji: "👍")
        try await core.api.removeReaction(messageId: "m1", emoji: "👍")
        try await core.api.markRead(channelId: "c1", seq: 77)
        let threads = try await core.api.threadSummaries(channelId: "c1", parentMessageIds: ["m1", "m2"])
        let created = try await core.api.createThread(channelId: "c1", parentMessageId: "m1")
        let inbox = try await core.api.inbox(filter: "unread", limit: 10)
        #expect(core.server.requests("DELETE messages/m1/reactions").first?.json == ["emoji": "👍"])
        #expect(core.server.requests("POST channels/c1/read").first?.json == ["seq": 77])
        #expect(threads.keys.sorted() == ["m1"])
        #expect(threads["m1"]?.replyCount == 3)
        #expect(core.server.requests("GET channels/c1/threads").first?.query["parentMessageIds"] == "m1,m2")
        #expect(created.threadChannelId == "t9")
        #expect(inbox.items.first?.hasMention == true)
        #expect(inbox.hasMore)
        #expect(core.server.requests("GET channels/inbox").first?.query == ["filter": "unread", "limit": "10", "offset": "0"])
    }

    @Test func attachmentsUploadMultipartAndURLs() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST attachments/upload", .json(200, #"{"attachments":[{"id":"a1","filename":"n.txt"}]}"#))
        core.server.on("POST attachments/urls", .json(200, #"{"urls":[{"id":"a1","url":"https://cdn.example/a1","expiresAt":"z"},{"id":"bad"}]}"#))
        core.server.on("GET attachments/a1/url", .json(200, #"{"url":"https://cdn.example/a1"}"#))
        let uploaded = try await core.api.uploadAttachments(channelId: "c1", files: [UploadFile(filename: "n.txt", mimeType: "text/plain", data: Data("hello".utf8))])
        #expect(uploaded.map(\.id) == ["a1"])
        let upload = try #require(core.server.requests("POST attachments/upload").first)
        let contentType = try #require(upload.header("Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: upload.body ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"channelId\"\r\n\r\nc1\r\n"))
        #expect(body.contains("name=\"files\"; filename=\"n.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n"))
        #expect(body.hasSuffix("--\r\n"))
        let urls = try await core.api.attachmentURLs(ids: ["a1", "bad"])
        #expect(urls.map(\.url.absoluteString) == ["https://cdn.example/a1"])
        #expect(core.server.requests("POST attachments/urls").first?.json == ["attachmentIds": ["a1", "bad"]])
        #expect(try await core.api.attachmentURL(id: "a1").url.host() == "cdn.example")
    }

    @Test func membersDecodeAnyEnvelope() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET servers/srv-2/members", replies: [
            .json(200, #"[{"userId":"u1","name":"Sam"}]"#),
            .json(200, #"{"members":[{"userId":"u2","name":"Al","role":"admin"}]}"#),
            .json(200, #"{"results":[{"id":"u3","name":"Jo"}]}"#),
        ])
        #expect(try await core.api.members(serverId: "srv-2").map(\.id) == ["u1"])
        #expect(try await core.api.members(serverId: "srv-2").first?.role == "admin")
        #expect(try await core.api.members(serverId: "srv-2").map(\.id) == ["u3"])
        #expect(core.server.requests.first?.header("X-Server-Id") == "srv-2")
    }

    @Test func serversDecodeLeniently() throws {
        let servers = try ListEnvelope<AuthServer>.decode(Data(#"[{"id":"s1","name":"One","hideHumansFromMembers":"yes"},{"name":"x"}]"#.utf8), keys: [], path: "servers", traceId: nil)
        #expect(servers.map(\.id) == ["s1"])
        #expect(servers.first?.hideHumansFromMembers == false)
    }

    @Test func jsonValueWritesCompactSortedJSON() {
        let value: JSONValue = ["b": [1, 2.5, "x\n\"y\""], "a": nil, "c": true]
        #expect(value.jsonString() == #"{"a":null,"b":[1,2.5,"x\n\"y\""],"c":true}"#)
        #expect(JSONValue.parse(value.jsonString()) == value)
        #expect(JSONValue.string("41").int64Value == 41)
        #expect(JSONValue.number(1.5).int64Value == nil)
    }
}
