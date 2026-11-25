import Foundation
import Testing
@testable import Raft

// MARK: Fixtures

func messageJSON(
    id: String,
    seq: Int64,
    channelId: String = "c1",
    senderId: String = "u-2",
    senderType: String = "user",
    content: String = "hi",
    randomId: String? = nil,
    mentions: String = "[]",
    extra: String = ""
) -> String {
    let random = randomId.map { #","randomId":"\#($0)""# } ?? ""
    return #"{"id":"\#(id)","seq":\#(seq),"channelId":"\#(channelId)","senderType":"\#(senderType)","senderId":"\#(senderId)","senderName":"S","content":"\#(content)","createdAt":"2026-11-0\#(min(9, max(1, seq % 10)))T10:00:00.000Z","mentions":\#(mentions)\#(random)\#(extra)}"#
}

func makeMessage(_ json: String) -> Message {
    try! RaftJSON.decode(Message.self, from: Data(json.utf8))
}

func pageJSON(_ messages: [String]) -> String {
    #"{"messages":[\#(messages.joined(separator: ","))],"historyLimited":false,"threadSummariesByParentMessageId":{}}"#
}

func readUpdate(_ json: String) -> ReadStateUpdate {
    try! RaftJSON.decode(ReadStateUpdate.self, from: Data(json.utf8))
}

let channelsJSON = #"[{"id":"c1","name":"general","type":"channel","joined":true,"lastMessageAt":"2026-11-01T10:00:00Z","readStateVersion":3,"maxReadSeq":10},{"id":"c2","name":"random","type":"channel","joined":true,"lastMessageAt":"2026-11-03T10:00:00Z"},{"id":"c3","name":"old","type":"channel","joined":true,"archivedAt":"2026-01-01T00:00:00Z"},{"id":"c4","name":"other","type":"channel","joined":false}]"#
let dmsJSON = #"[{"id":"d1","name":"dm-1","type":"dm","peerType":"agent","peerId":"a1","peerName":"Bot","lastMessageAt":"2026-11-02T10:00:00Z","lastMessagePreview":"yo"}]"#
let unreadJSON = #"{"channels":{"c1":{"unreadCount":2,"hasMention":true},"d1":{"unreadCount":1,"hasMention":false}},"threadUnread":{}}"#

@MainActor
func listStore(_ core: TestCore) -> ChannelListStore {
    ChannelListStore(api: core.api, serverId: "srv-1", currentUserId: "u-1")
}

@MainActor
func conversationStore(_ core: TestCore, readOnly: Bool = false, channelId: String = "c1") -> ConversationStore {
    ConversationStore(channelId: channelId, kind: .channel, title: "general", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: readOnly))
}

/// Records joins and leaves; delivers scripted events.
final class FakeRealtime: RealtimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var joined: [String] = []
    private var left: [String] = []
    private var continuation: AsyncStream<RealtimeEvent>.Continuation?

    var joins: [String] { lock.withLock { joined } }
    var leaves: [String] { lock.withLock { left } }

    func joinChannel(_ channelId: String) async { lock.withLock { joined.append(channelId) } }
    func leaveChannel(_ channelId: String) async { lock.withLock { left.append(channelId) } }

    func events() async -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func statuses() async -> AsyncStream<RealtimeStatus> {
        AsyncStream { $0.yield(.connected(sid: "s")) }
    }

    func start() async {}
    func stop(reason: String) async {}
    func reconnectNow() async {}

    func push(_ event: RealtimeEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }
}

// MARK: Home list

@MainActor
struct ChannelListStoreTests {
    @Test func loadsAndOrdersMentionsThenUnreadThenRecent() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, channelsJSON))
        core.server.on("GET channels/dm", .json(200, dmsJSON))
        core.server.on("GET channels/unread", .json(200, unreadJSON))
        let store = listStore(core)
        await store.load()
        #expect(store.phase == .loaded)
        // Archived and unjoined channels are not listed.
        #expect(store.rows.map(\.id) == ["c1", "d1", "c2"])
        #expect(store.rows.map(\.priority) == [.mention, .unread, .quiet])
        #expect(store.mentionCount == 1)
        #expect(store.attentionCount == 2)
        #expect(store.row(id: "d1")?.title == "Bot")
    }

    @Test func aDMWithYourselfSaysSo() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, "[]"))
        core.server.on("GET channels/dm", .json(200, #"[{"id":"d1","name":"dm-1","type":"dm","peerType":"agent","peerId":"a1","peerName":"Bot"},{"id":"d2","name":"dm-2","type":"dm","peerType":"user","peerId":"u-1","peerName":"xin","peerDisplayName":"XIN"}]"#))
        core.server.on("GET channels/unread", .json(200, #"{"channels":{},"threadUnread":{}}"#))
        let store = listStore(core)
        await store.load()
        let suffix = L10n.t("member_label_you_suffix", "(you)")
        // The plain name stays the row's title (order, identifiers, initials).
        #expect(store.row(id: "d2")?.title == "XIN")
        #expect(store.row(id: "d2")?.isSelf == true)
        #expect(store.row(id: "d2")?.displayTitle.hasPrefix("XIN") == true)
        #expect(store.row(id: "d2")?.displayTitle.hasSuffix(suffix) == true)
        #expect(store.directMessages.last?.displayTitle(currentUserId: "u-1") == store.row(id: "d2")?.displayTitle)
        #expect(store.row(id: "d1")?.isSelf == false)
        #expect(store.row(id: "d1")?.displayTitle == "Bot")
    }

    @Test func unreadFailureKeepsListsAndMarksStale() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, channelsJSON))
        core.server.on("GET channels/dm", .json(200, dmsJSON))
        core.server.on("GET channels/unread", .json(500, "{}"))
        let store = listStore(core)
        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.unreadIsStale)
    }

    @Test func listFailureIsShownWhenEmpty() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(500, "{}"))
        core.server.on("GET channels/dm", .json(200, dmsJSON))
        core.server.on("GET channels/unread", .json(200, unreadJSON))
        let store = listStore(core)
        await store.load()
        if case .failed = store.phase {} else { Issue.record("expected failed, got \(store.phase)") }
    }

    @Test func readStateIsVersionGated() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, channelsJSON))
        core.server.on("GET channels/dm", .json(200, dmsJSON))
        core.server.on("GET channels/unread", .json(200, unreadJSON))
        let store = listStore(core)
        await store.load()
        // c1 holds version 3: an older or equal version is stale.
        store.applyReadState(readUpdate(#"{"serverId":"srv-1","scopeId":"c1","maxReadSeq":20,"readStateVersion":3,"unreadCount":0}"#))
        #expect(store.row(id: "c1")?.unreadCount == 2)
        store.applyReadState(readUpdate(#"{"serverId":"srv-1","scopeId":"c1","maxReadSeq":20,"readStateVersion":4,"unreadCount":0}"#))
        #expect(store.row(id: "c1")?.unreadCount == 0)
        #expect(store.row(id: "c1")?.hasMention == false)
        #expect(store.row(id: "c1")?.maxReadSeq == 20)
        // Another server's event is ignored.
        store.applyReadState(readUpdate(#"{"serverId":"srv-2","scopeId":"c1","readStateVersion":9,"unreadCount":5}"#))
        #expect(store.row(id: "c1")?.unreadCount == 0)
    }

    @Test func liveMessagesCountUnlessMineOrViewedOrAlreadyRead() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, channelsJSON))
        core.server.on("GET channels/dm", .json(200, dmsJSON))
        core.server.on("GET channels/unread", .json(200, #"{"channels":{},"threadUnread":{}}"#))
        let store = listStore(core)
        await store.load()
        store.noteMessage(makeMessage(messageJSON(id: "m1", seq: 30, channelId: "c2")), viewing: false)
        #expect(store.row(id: "c2")?.unreadCount == 1)
        store.noteMessage(makeMessage(messageJSON(id: "m2", seq: 31, channelId: "c2", senderId: "u-1")), viewing: false)
        #expect(store.row(id: "c2")?.unreadCount == 1)
        store.noteMessage(makeMessage(messageJSON(id: "m3", seq: 32, channelId: "c2")), viewing: true)
        #expect(store.row(id: "c2")?.unreadCount == 1)
        // c1 has read up to seq 10.
        store.noteMessage(makeMessage(messageJSON(id: "m4", seq: 9, channelId: "c1")), viewing: false)
        #expect(store.row(id: "c1")?.unreadCount == 0)
        let mention = #"[{"type":"user","id":"u-1","name":"Person"}]"#
        store.noteMessage(makeMessage(messageJSON(id: "m5", seq: 33, channelId: "c1", mentions: mention)), viewing: false)
        #expect(store.row(id: "c1")?.priority == .mention)
        #expect(store.rows.first?.id == "c1")
        // DM preview follows the newest message.
        store.noteMessage(makeMessage(messageJSON(id: "m6", seq: 34, channelId: "d1", content: "latest")), viewing: false)
        #expect(store.row(id: "d1")?.preview == "latest")
    }

    @Test func channelUpdateUpsertsFullRowsOfThisServer() async {
        let core = TestCore(session: sampleSession())
        let store = listStore(core)
        let raw = JSONValue.parse(Data(#"{"channel":{"id":"c9","name":"new","type":"channel","joined":true,"serverId":"srv-1"}}"#.utf8))!
        await store.applyChannelUpdate(channelId: "c9", raw: raw)
        #expect(store.row(id: "c9")?.title == "new")
        let foreign = JSONValue.parse(Data(#"{"channel":{"id":"c8","name":"x","type":"channel","joined":true,"serverId":"srv-2"}}"#.utf8))!
        await store.applyChannelUpdate(channelId: "c8", raw: foreign)
        #expect(store.row(id: "c8") == nil)
    }
}

// MARK: Conversation

@MainActor
struct ConversationStoreTests {
    @Test func loadsLatestThenOlderPages() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1") { request, _ in
            if request.query["before"] == "3" { return .json(200, pageJSON([messageJSON(id: "m1", seq: 1), messageJSON(id: "m2", seq: 2)])) }
            return .json(200, pageJSON([messageJSON(id: "m4", seq: 4), messageJSON(id: "m3", seq: 3)]))
        }
        let store = conversationStore(core)
        store.pageSize = 2
        await store.start()
        #expect(store.messages.map(\.id) == ["m3", "m4"])
        #expect(store.hasOlder)
        await store.loadOlder()
        #expect(store.messages.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(store.hasOlder)
    }

    @Test func liveMessagesAppendOnceAndUpdatesReplace() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([messageJSON(id: "m1", seq: 1)])))
        let store = conversationStore(core)
        await store.start()
        store.receive(makeMessage(messageJSON(id: "m2", seq: 2)))
        store.receive(makeMessage(messageJSON(id: "m2", seq: 2)))
        store.receive(makeMessage(messageJSON(id: "x", seq: 3, channelId: "other")))
        #expect(store.messages.map(\.id) == ["m1", "m2"])
        store.applyUpdate(makeMessage(messageJSON(id: "m1", seq: 1, content: "", extra: #","deletedAt":"2026-11-02T00:00:00Z""#)))
        #expect(store.message(id: "m1")?.isDeleted == true)
    }

    @Test func optimisticSendIsReplacedByTheServerCopy() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([messageJSON(id: "m1", seq: 1)])))
        core.server.on("POST v2/messages") { request, _ in
            let randomId = request.json?["randomId"]?.stringValue ?? ""
            return .json(201, #"{"message":\#(messageJSON(id: "m2", seq: 2, senderId: "u-1", content: "hello", randomId: randomId))}"#)
        }
        let store = conversationStore(core)
        await store.start()
        await store.send("  hello ")
        #expect(store.pending.isEmpty)
        #expect(store.messages.map(\.id) == ["m1", "m2"])
        let sent = core.server.requests("POST v2/messages").first?.json
        #expect(sent?["content"]?.stringValue == "hello")
        #expect(sent?["randomId"]?.stringValue?.hasPrefix("ios-") == true)
        // The socket echo of the same message does not duplicate it.
        store.receive(store.messages[1])
        #expect(store.messages.count == 2)
    }

    @Test func enqueuedRowShowsAtOnceAsSendingThenTurnsIntoTheServerCopy() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([messageJSON(id: "m1", seq: 1)])))
        core.server.on("POST v2/messages") { request, _ in
            let randomId = request.json?["randomId"]?.stringValue ?? ""
            return .json(201, #"{"message":\#(messageJSON(id: "m2", seq: 2, senderId: "u-1", content: "hello", randomId: randomId))}"#)
        }
        let store = conversationStore(core)
        await store.start()
        // On the tap: the row is there, sending, before any request.
        let randomId = store.enqueue("hello") ?? ""
        #expect(!randomId.isEmpty)
        #expect(store.pending.map(\.randomId) == [randomId])
        #expect(store.pending.first?.state == .sending)
        #expect(core.server.count("POST v2/messages") == 0)
        await store.deliver(randomId, attachmentIds: [])
        #expect(store.pending.isEmpty)
        #expect(store.messages.map(\.id) == ["m1", "m2"])
        #expect(core.server.requests("POST v2/messages").first?.json?["randomId"]?.stringValue == randomId)
        // The socket copy of the same message does not add a second row.
        store.receive(makeMessage(messageJSON(id: "m2", seq: 2, senderId: "u-1", content: "hello", randomId: randomId)))
        #expect(store.messages.map(\.id) == ["m1", "m2"])
        #expect(store.pending.isEmpty)
    }

    @Test func socketCopyBeforeTheAnswerReplacesThePendingRowOnce() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([])))
        let store = conversationStore(core)
        await store.start()
        let randomId = store.enqueue("hello") ?? ""
        store.receive(makeMessage(messageJSON(id: "m2", seq: 2, senderId: "u-1", content: "hello", randomId: randomId)))
        #expect(store.pending.isEmpty)
        #expect(store.messages.map(\.id) == ["m2"])
    }

    @Test func filesOnlySendWhoseUploadsAllFailedIsDropped() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([])))
        let store = conversationStore(core)
        await store.start()
        let randomId = store.enqueue("", hasAttachments: true, attachmentNames: ["a.png"]) ?? ""
        #expect(store.pending.first?.attachmentNames == ["a.png"])
        await store.deliver(randomId, attachmentIds: [])
        #expect(store.pending.isEmpty)
        #expect(store.errorMessage != nil)
        #expect(core.server.count("POST v2/messages") == 0)
    }

    @Test func failedSendStaysPendingAndRetriesWithTheSameRandomId() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([])))
        core.server.on("POST v2/messages", replies: [.json(500, #"{"error":"boom"}"#), .json(500, #"{"error":"boom"}"#)])
        let store = conversationStore(core)
        await store.start()
        await store.send("hello")
        #expect(store.pending.count == 1)
        guard let item = store.pending.first, case .failed = item.state else {
            Issue.record("expected a failed pending send")
            return
        }
        // A message:new carrying the randomId confirms it.
        store.receive(makeMessage(messageJSON(id: "m9", seq: 9, senderId: "u-1", content: "hello", randomId: item.randomId)))
        #expect(store.pending.isEmpty)
        #expect(store.messages.map(\.id) == ["m9"])
    }

    @Test func readOnlyBlocksSendReactionsAndReadReceipts() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([messageJSON(id: "m1", seq: 1)])))
        let store = conversationStore(core, readOnly: true)
        await store.start()
        store.isVisible = true
        await store.send("hello")
        await store.toggleReaction("👍", on: "m1")
        await store.markReadIfNeeded()
        #expect(store.pending.isEmpty)
        #expect(store.errorMessage == StoreError.readOnly.errorDescription)
        #expect(core.server.count("POST v2/messages") == 0)
        #expect(core.server.count("POST messages/m1/reactions") == 0)
        #expect(core.server.count("POST channels/c1/read") == 0)
    }

    @Test func marksReadOnlyWhenVisible() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([messageJSON(id: "m1", seq: 5)])))
        core.server.on("POST channels/c1/read", .json(200, "{}"))
        let store = conversationStore(core)
        var reads: [Int64] = []
        store.onRead = { _, seq in reads.append(seq) }
        await store.start()
        await store.markReadIfNeeded()
        #expect(core.server.count("POST channels/c1/read") == 0)
        store.isVisible = true
        await store.markReadIfNeeded()
        #expect(core.server.requests("POST channels/c1/read").first?.json?["seq"]?.int64Value == 5)
        #expect(reads == [5])
        store.markReadCoalescer.cancel()
    }

    @Test func agentTypingLinesStartEndAndClearOnMessage() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([])))
        let store = conversationStore(core)
        await store.start()
        store.applyTyping(AgentTyping(agentId: "a1", serverId: "srv-1", channelId: "c1", callId: "k1", isStart: true))
        store.applyTyping(AgentTyping(agentId: "a2", serverId: "srv-1", channelId: "c1", callId: "k2", isStart: true))
        // A thread line does not show in the channel.
        store.applyTyping(AgentTyping(agentId: "a3", serverId: "srv-1", channelId: "c1", parentMessageId: "p", callId: "k3", isStart: true))
        #expect(store.typingAgentIds == ["a1", "a2"])
        store.applyTyping(AgentTyping(agentId: "a2", serverId: "srv-1", channelId: "c1", callId: "k2", isStart: false))
        #expect(store.typingAgentIds == ["a1"])
        store.receive(makeMessage(messageJSON(id: "m1", seq: 1, senderId: "a1", senderType: "agent")))
        #expect(store.typingAgentIds.isEmpty)
    }

    @Test func threadUpdatesCountRepliesUnderHeldParents() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([messageJSON(id: "m1", seq: 1)])))
        let store = conversationStore(core)
        await store.start()
        let update = try! RaftJSON.decode(ThreadUpdate.self, from: Data(#"{"parentMessageId":"m1","threadChannelId":"t1","replyCount":3,"lastReplyAt":"2026-11-02T00:00:00Z","participantIds":["u-2"]}"#.utf8))
        store.applyThreadUpdate(update)
        #expect(store.threads["m1"]?.replyCount == 3)
        #expect(store.threads["m1"]?.threadChannelId == "t1")
    }
}

// MARK: Thread and Activity

@MainActor
struct ThreadAndActivityStoreTests {
    @Test func threadLoadsRepliesAndJoinsItsRoom() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/t1", .json(200, pageJSON([messageJSON(id: "r1", seq: 7, channelId: "t1")])))
        let realtime = FakeRealtime()
        let workspace = Workspace(serverId: "srv-1", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: true), realtime: realtime)
        let parent = makeMessage(messageJSON(id: "p1", seq: 1))
        let store = workspace.thread(for: ThreadRef(parentChannelId: "c1", parentMessageId: "p1", threadChannelId: "t1", title: "general", parent: parent))
        await store.start()
        #expect(store.replies?.messages.map(\.id) == ["r1"])
        #expect(realtime.joins == ["t1"])
        await store.stop()
        #expect(realtime.leaves == ["t1"])
    }

    @Test func threadWithoutRepliesDoesNotCreateOneUntilSending() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels/c1/threads", .json(200, "{}"))
        let workspace = Workspace(serverId: "srv-1", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: true), realtime: FakeRealtime())
        let store = workspace.thread(for: ThreadRef(parentChannelId: "c1", parentMessageId: "p1", title: "general", parent: makeMessage(messageJSON(id: "p1", seq: 1))))
        await store.start()
        #expect(store.phase == .loaded)
        #expect(store.replies == nil)
        await store.sendReply("hi")
        #expect(core.server.count("POST channels/c1/threads") == 0)
        #expect(store.errorMessage == StoreError.readOnly.errorDescription)
    }

    @Test func firstReplyShowsAtOnceThenCreatesTheThreadAndBecomesTheServerCopy() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels/c1/threads", .json(200, "{}"))
        core.server.on("POST channels/c1/threads", .json(201, #"{"threadChannelId":"t1","parentMessageId":"p1","created":true}"#))
        core.server.on("GET messages/channel/t1", .json(200, pageJSON([])))
        core.server.on("POST v2/messages") { request, _ in
            let randomId = request.json?["randomId"]?.stringValue ?? ""
            return .json(201, #"{"message":\#(messageJSON(id: "r1", seq: 1, channelId: "t1", senderId: "u-1", content: "hi", randomId: randomId))}"#)
        }
        let workspace = Workspace(serverId: "srv-1", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: false), realtime: FakeRealtime())
        let store = workspace.thread(for: ThreadRef(parentChannelId: "c1", parentMessageId: "p1", title: "general", parent: makeMessage(messageJSON(id: "p1", seq: 1))))
        await store.start()
        #expect(store.replies == nil)
        // On the tap: shown, sending, before the thread exists.
        let randomId = store.enqueueReply("hi") ?? ""
        #expect(!randomId.isEmpty)
        #expect(store.pendingBeforeThread.map(\.randomId) == [randomId])
        #expect(store.pendingBeforeThread.first?.state == .sending)
        #expect(core.server.count("POST channels/c1/threads") == 0)
        await store.deliverReply(randomId, attachmentIds: [])
        #expect(core.server.count("POST channels/c1/threads") == 1)
        #expect(store.pendingBeforeThread.isEmpty)
        #expect(store.replies?.pending.isEmpty == true)
        #expect(store.replies?.messages.map(\.id) == ["r1"])
        #expect(core.server.requests("POST v2/messages").first?.json?["randomId"]?.stringValue == randomId)
        #expect(store.isFollowing == true)
        // The socket copy does not add a second row.
        store.replies?.receive(makeMessage(messageJSON(id: "r1", seq: 1, channelId: "t1", senderId: "u-1", content: "hi", randomId: randomId)))
        #expect(store.replies?.messages.map(\.id) == ["r1"])
    }

    @Test func firstReplyWhoseThreadFailsTurnsFailedAndRetries() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels/c1/threads", .json(200, "{}"))
        core.server.on("POST channels/c1/threads", .json(500, #"{"error":"boom"}"#))
        core.server.on("GET messages/channel/t1", .json(200, pageJSON([])))
        core.server.on("POST v2/messages") { request, _ in
            let randomId = request.json?["randomId"]?.stringValue ?? ""
            return .json(201, #"{"message":\#(messageJSON(id: "r1", seq: 1, channelId: "t1", senderId: "u-1", content: "hi", randomId: randomId))}"#)
        }
        let workspace = Workspace(serverId: "srv-1", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: false), realtime: FakeRealtime())
        let store = workspace.thread(for: ThreadRef(parentChannelId: "c1", parentMessageId: "p1", title: "general", parent: makeMessage(messageJSON(id: "p1", seq: 1))))
        await store.start()
        await store.sendReply("hi")
        guard let item = store.pendingBeforeThread.first, case .failed = item.state else {
            Issue.record("expected a failed first reply")
            return
        }
        #expect(core.server.count("POST v2/messages") == 0)
        core.server.on("POST channels/c1/threads", .json(201, #"{"threadChannelId":"t1"}"#))
        await store.retryBeforeThread(item.randomId)
        #expect(store.pendingBeforeThread.isEmpty)
        #expect(store.replies?.messages.map(\.id) == ["r1"])
        #expect(core.server.requests("POST v2/messages").first?.json?["randomId"]?.stringValue == item.randomId)
    }

    @Test func systemNoticesAreFromSystemNotSomeone() throws {
        // A task row's status notice: a "user" sender whose id is "system", no name.
        let task = try RaftJSON.decode(InboxItem.self, from: Data(#"{"kind":"task","threadChannelId":"t2","parentMessageId":"p2","parentChannelId":"c1","parentChannelName":"general","latestActivitySenderId":"system","latestActivitySenderType":"user","latestActivityPreview":"moved #1","unreadCount":0}"#.utf8))
        #expect(ActivityRow.isSystemSender(task))
        #expect(ActivityRow.senderName(task) == L10n.t("ios_activity_system_sender", "System"))
        let unnamed = try RaftJSON.decode(InboxItem.self, from: Data(#"{"kind":"thread","threadChannelId":"t3","parentMessageId":"p3","parentChannelId":"c1","latestActivitySenderId":"u-9","latestActivitySenderType":"user","unreadCount":0}"#.utf8))
        #expect(!ActivityRow.isSystemSender(unnamed))
        #expect(ActivityRow.senderName(unnamed) == L10n.t("ios_activity_someone", "Someone"))
    }

    @Test func inboxRowsDecodeAndRoute() async throws {
        let json = #"{"items":[{"kind":"channel","channelId":"c1","channelName":"general","channelType":"channel","lastMessageId":"m5","unreadCount":2,"hasMention":true,"firstMentionMessageId":"m3","readStateVersion":2},{"kind":"thread","threadChannelId":"t1","parentMessageId":"p1","parentChannelId":"c1","parentChannelName":"general","latestActivityPreview":"reply","latestActivityMessageId":"r9","unreadCount":1,"hasMention":false},{"kind":"app","id":"obj-1","unreadCount":0}],"hasMore":false,"totalUnreadCount":3}"#
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels/inbox", .json(200, json))
        let store = ActivityStore(api: core.api, currentUserId: "u-1")
        await store.load()
        #expect(store.items.map(\.id) == ["channel:c1", "thread:t1", "app:obj-1"])
        #expect(store.unreadRowCount == 2)
        #expect(store.route(for: store.items[0]) == .conversation(ConversationRef(channelId: "c1", title: "general", kind: .channel, focusMessageId: "m3")))
        #expect(store.route(for: store.items[1]) == .thread(ThreadRef(parentChannelId: "c1", parentMessageId: "p1", threadChannelId: "t1", title: "general", focusMessageId: "r9")))
        #expect(store.route(for: store.items[2]) == nil)
        store.applyReadState(readUpdate(#"{"scopeId":"c1","readStateVersion":2,"unreadCount":0}"#))
        #expect(store.items[0].unreadCount == 2)
        store.applyReadState(readUpdate(#"{"scopeId":"t1","readStateVersion":1,"unreadCount":0}"#))
        #expect(store.items[1].unreadCount == 0)
    }
}

// MARK: Workspace routing

@MainActor
struct WorkspaceRoutingTests {
    func makeWorkspace(_ core: TestCore, readOnly: Bool = false) -> (Workspace, FakeRealtime) {
        core.server.on("GET channels", .json(200, channelsJSON))
        core.server.on("GET channels/dm", .json(200, dmsJSON))
        core.server.on("GET channels/unread", .json(200, #"{"channels":{},"threadUnread":{}}"#))
        core.server.on("GET messages/channel/c2", .json(200, pageJSON([messageJSON(id: "m1", seq: 1, channelId: "c2")])))
        let realtime = FakeRealtime()
        return (Workspace(serverId: "srv-1", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: readOnly), realtime: realtime), realtime)
    }

    @Test func socketMessagesReachTheListAndTheOpenConversation() async {
        let core = TestCore(session: sampleSession())
        let (workspace, realtime) = makeWorkspace(core, readOnly: true)
        await workspace.start()
        let store = workspace.conversation(for: ConversationRef(channelId: "c2", title: "random", kind: .channel))
        await store.start()
        realtime.push(.messageNew(makeMessage(messageJSON(id: "m2", seq: 2, channelId: "c2"))))
        #expect(await eventually { await MainActor.run { store.messages.count == 2 } })
        // Read-only: viewing does not read it, so it still counts.
        #expect(workspace.channelList.row(id: "c2")?.unreadCount == 1)
        #expect(workspace.conversation(for: ConversationRef(channelId: "c2", title: "", kind: .channel)) === store)
        await workspace.stop()
    }

    @Test func routesUpdatesTypingReadStateAndNewDMs() async {
        let core = TestCore(session: sampleSession())
        let (workspace, realtime) = makeWorkspace(core)
        await workspace.channelList.load()
        let store = workspace.conversation(for: ConversationRef(channelId: "c2", title: "random", kind: .channel))
        await store.start()
        await workspace.handle(.messageUpdated(makeMessage(messageJSON(id: "m1", seq: 1, channelId: "c2", content: "edited"))))
        #expect(store.message(id: "m1")?.content == "edited")
        await workspace.handle(.agentTyping(AgentTyping(agentId: "a1", serverId: "srv-1", channelId: "c2", callId: "k", isStart: true)))
        await workspace.handle(.agentTyping(AgentTyping(agentId: "a2", serverId: "srv-2", channelId: "c2", callId: "k", isStart: true)))
        #expect(store.typingAgentIds == ["a1"])
        await workspace.handle(.readStateUpdatedBulk([readUpdate(#"{"serverId":"srv-1","scopeId":"c1","readStateVersion":9,"unreadCount":4}"#)]))
        #expect(workspace.channelList.row(id: "c1")?.unreadCount == 4)
        await workspace.handle(.directMessageNew(channelId: "d9"))
        #expect(realtime.joins == ["d9"])
        await workspace.handle(.roomsJoinFailed)
        #expect(workspace.isDegraded)
        await workspace.handle(.roomsJoined)
        #expect(!workspace.isDegraded)
        workspace.channelList.unreadRefresh.cancel()
        workspace.channelList.dmRefresh.cancel()
    }

    @Test func membershipEventsForThisUserReloadServers() async {
        let core = TestCore(session: sampleSession())
        let (workspace, _) = makeWorkspace(core)
        var calls = 0
        workspace.onMembershipChange = { calls += 1 }
        await workspace.handle(.serverMembership(name: SocketEventName.serverMemberRemoved, serverId: "srv-1", userId: "u-9"))
        await workspace.handle(.serverMembership(name: SocketEventName.serverMemberRemoved, serverId: "srv-1", userId: "u-1"))
        #expect(calls == 1)
    }
}

// MARK: Event decoding

struct StoreEventDecodingTests {
    @Test func decodesAgentTyping() {
        let payload = JSONValue.parse(Data(#"{"agentId":"a1","serverId":"s","channelId":"c","parentMessageId":null,"callId":"k","state":"start","expiresAt":1000}"#.utf8))!
        guard case .agentTyping(let typing) = RealtimeEvent.decode(name: "agent:typing", args: [payload]) else {
            Issue.record("not decoded")
            return
        }
        #expect(typing.isStart && typing.parentMessageId == nil && typing.expiresAtMs == 1000)
        // A far-off or past expiry falls back to the TTL.
        let now = Date(timeIntervalSince1970: 100)
        #expect(typing.deadline(now: now) == now.addingTimeInterval(AgentTyping.ttl))
        let bad = JSONValue.parse(Data(#"{"agentId":"a1","serverId":"s","channelId":"c","callId":"k","state":"maybe"}"#.utf8))!
        if case .agentTyping = RealtimeEvent.decode(name: "agent:typing", args: [bad]) { Issue.record("bad state decoded") }
    }

    @Test func decodesThreadUpdateWithLatestReplyAndJoinFailed() {
        let payload = JSONValue.parse(Data(#"{"parentMessageId":"p","threadChannelId":"t","replyCount":2,"participantIds":["a"],"latestReply":\#(messageJSON(id: "r", seq: 3, channelId: "t"))}"#.utf8))!
        guard case .threadUpdated(let update) = RealtimeEvent.decode(name: "thread:updated", args: [payload]) else {
            Issue.record("not decoded")
            return
        }
        #expect(update.latestReply?.id == "r")
        #expect(update.participantIds == ["a"])
        #expect(RealtimeEvent.decode(name: "rooms:join_failed", args: []) == .roomsJoinFailed)
    }
}
