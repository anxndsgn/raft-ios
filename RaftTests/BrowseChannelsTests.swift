import Foundation
import Testing
@testable import Raft

// MARK: Fixtures

/// c1 general (joined), c2 Research (public, not joined, topic), c3 design-private (private, joined),
/// c4 secret (private, not joined: never listed), c5 old (archived), c6 all (joined), d1 a DM row,
/// c7 alpha (public, not joined).
private let browseChannelsJSON = #"""
[{"id":"c1","name":"general","type":"channel","joined":true},
 {"id":"c2","name":"Research","type":"channel","joined":false,"description":"Papers and notes"},
 {"id":"c3","name":"design-private","type":"private","joined":true},
 {"id":"c4","name":"secret","type":"private","joined":false},
 {"id":"c5","name":"old","type":"channel","joined":false,"archivedAt":"2026-01-01T00:00:00Z"},
 {"id":"c6","name":"all","type":"channel","joined":true},
 {"id":"d1","name":"dm-1","type":"dm","joined":true},
 {"id":"c7","name":"alpha","type":"channel","joined":false}]
"""#

private func channels(_ json: String) -> [Channel] {
    try! RaftJSON.decode(LenientArray<Channel>.self, from: Data(json.utf8)).elements
}

private func channel(_ json: String) -> Channel {
    try! RaftJSON.decode(Channel.self, from: Data(json.utf8))
}

@MainActor
private func browseWorkspace(_ core: TestCore, readOnly: Bool = false, realtime: FakeRealtime = FakeRealtime()) async -> Workspace {
    core.server.on("GET channels", .json(200, browseChannelsJSON))
    core.server.on("GET channels/dm", .json(200, "[]"))
    core.server.on("GET channels/unread", .json(200, #"{"channels":{"c3":{"unreadCount":2,"hasMention":true}},"threadUnread":{}}"#))
    let workspace = Workspace(serverId: "srv-1", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: readOnly), realtime: realtime)
    await workspace.channelList.load()
    return workspace
}

// MARK: Model

struct BrowseChannelModelTests {
    @Test func missingJoinedCountsAsJoinedAndIsRemembered() {
        let bare = channel(#"{"id":"c1","name":"general","type":"channel"}"#)
        #expect(bare.joined)
        #expect(bare.joinedField == nil)
        let explicit = channel(#"{"id":"c1","name":"general","type":"channel","joined":false}"#)
        #expect(!explicit.joined)
        #expect(explicit.joinedField == false)
    }

    @Test func decodesOptionalCountAndCreator() {
        let plain = channel(#"{"id":"c1","name":"general","type":"channel","joined":true}"#)
        #expect(plain.memberCount == nil)
        #expect(plain.createdByName == nil)
        let rich = channel(#"{"id":"c1","name":"general","type":"channel","memberCount":"18","createdBy":"u-9","createdByName":"XIN","createdAt":"2026-03-04T10:00:00Z"}"#)
        #expect(rich.memberCount == 18)
        #expect(rich.createdById == "u-9")
        #expect(rich.createdByName == "XIN")
        #expect(rich.createdAt == "2026-03-04T10:00:00Z")
    }

    @Test func leaveRuleFollowsTheOldApp() {
        let list = channels(browseChannelsJSON)
        func canLeave(_ id: String) -> Bool { list.first { $0.id == id }!.canLeave }
        #expect(canLeave("c1"))
        #expect(canLeave("c3"))
        #expect(!canLeave("c2"))  // not joined
        #expect(!canLeave("c5"))  // archived
        #expect(!canLeave("c6"))  // #all
        #expect(!canLeave("d1"))  // DM
        #expect(!channel(##"{"id":"x","name":"#ALL","type":"channel","joined":true}"##).canLeave)
        #expect(channel(#"{"id":"x","name":"j","type":"joint","joined":true}"#).isPrivate)
    }

    @Test func rosterDecodesHumansAndAgentsCreatorFirst() throws {
        let json = #"{"humans":[{"id":"u-2","name":"zed"},{"id":"u-9","name":"xin","displayName":"XIN"},{"name":"no-id"}],"agents":[{"id":"a1","name":"atlas","displayName":"Atlas","avatarUrl":"pixel:fox"}],"externalMembers":[]}"#
        let roster = try RaftJSON.decode(ChannelRoster.self, from: Data(json.utf8))
        #expect(roster.members.map(\.id) == ["u-2", "u-9", "a1"])
        #expect(roster.members.last?.kind == .agent)
        #expect(roster.members.last?.pixelKey == "fox")
        let ordered = ChannelMember.ordered(roster.members, creatorId: "u-9")
        #expect(ordered.map(\.id) == ["u-9", "a1", "u-2"])
        let bare = try RaftJSON.decode(ChannelRoster.self, from: Data(#"[{"id":"u-1","name":"me"}]"#.utf8))
        #expect(bare.members.map(\.id) == ["u-1"])
    }
}

// MARK: Grouping and search

struct BrowseGroupsTests {
    @Test func publicUnjoinedThenJoinedEachByName() {
        let groups = BrowseGroups.make(channels(browseChannelsJSON), query: "")
        // Private unjoined (c4), archived (c5) and DMs never show.
        #expect(groups.notJoined.map(\.id) == ["c7", "c2"])
        #expect(groups.joined.map(\.id) == ["c6", "c3", "c1"])
    }

    @Test func searchIsACaseInsensitiveSubstringOfTheNameOnly() {
        let list = channels(browseChannelsJSON)
        let research = BrowseGroups.make(list, query: "SEAR")
        #expect(research.notJoined.map(\.id) == ["c2"])
        #expect(research.joined.isEmpty)
        // The topic ("Papers and notes") is not searched.
        #expect(BrowseGroups.make(list, query: "papers").isEmpty)
        let shared = BrowseGroups.make(list, query: "al")
        #expect(shared.notJoined.map(\.id) == ["c7"])
        #expect(shared.joined.map(\.id) == ["c6", "c1"])
        #expect(BrowseGroups.make(list, query: "  xyz ").isEmpty)
    }

    @Test func matchRangeMarksTheMatchedPart() {
        let name = "Research"
        let range = BrowseGroups.matchRange(in: name, query: "sea")
        #expect(range.map { String(name[$0]) } == "sea")
        #expect(BrowseGroups.matchRange(in: name, query: "") == nil)
        #expect(BrowseGroups.matchRange(in: name, query: "zz") == nil)
    }
}

// MARK: List store

@MainActor
struct BrowseListStoreTests {
    @Test func channelUpdateWithoutJoinedKeepsTheKnownState() async {
        let core = TestCore(session: sampleSession())
        let workspace = await browseWorkspace(core)
        let list = workspace.channelList
        #expect(list.channelRows.map(\.id).contains("c1"))
        // `channel:updated` rows are the stored row: no `joined`.
        await list.applyChannelUpdate(channelId: "c1", raw: JSONValue.parse(Data(#"{"channel":{"id":"c1","name":"general-2","type":"channel","serverId":"srv-1"}}"#.utf8))!)
        #expect(list.row(id: "c1")?.title == "general-2")
        #expect(list.channel(id: "c1")?.joined == true)
        await list.applyChannelUpdate(channelId: "c2", raw: JSONValue.parse(Data(#"{"channel":{"id":"c2","name":"Research","type":"channel","serverId":"srv-1"}}"#.utf8))!)
        #expect(list.channel(id: "c2")?.joined == false)
        // A row the list does not hold, without `joined`, stays out of Home.
        await list.applyChannelUpdate(channelId: "c9", raw: JSONValue.parse(Data(#"{"channel":{"id":"c9","name":"new","type":"channel","serverId":"srv-1"}}"#.utf8))!)
        #expect(list.channel(id: "c9")?.joined == false)
        #expect(!list.channelRows.map(\.id).contains("c9"))
    }

    @Test func previewIsAnUnjoinedChannel() async {
        let core = TestCore(session: sampleSession())
        let workspace = await browseWorkspace(core)
        #expect(workspace.channelList.isPreview("c2"))
        #expect(!workspace.channelList.isPreview("c1"))
        #expect(!workspace.channelList.isPreview("nope"))
        let store = workspace.conversation(for: ConversationRef(channelId: "c2", title: "Research", kind: .channel))
        #expect(store.isPreview)
        #expect(!workspace.conversation(for: ConversationRef(channelId: "c1", title: "general", kind: .channel)).isPreview)
    }

    @Test func memberCountIsReadOnceAndCached() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels/c2/members", .json(200, #"{"humans":[{"id":"u-1","name":"a"},{"id":"u-2","name":"b"}],"agents":[{"id":"a1","name":"bot"}]}"#))
        let workspace = await browseWorkspace(core)
        await workspace.channelList.loadMemberCount("c2")
        await workspace.channelList.loadMemberCount("c2")
        #expect(workspace.channelList.memberCount("c2") == 3)
        #expect(core.server.count("GET channels/c2/members") == 1)
    }
}

// MARK: Preview read receipts

@MainActor
struct PreviewReadTests {
    @Test func aPreviewIsNeverMarkedReadUntilJoined() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET messages/channel/c2", .json(200, pageJSON([messageJSON(id: "m1", seq: 5, channelId: "c2")])))
        core.server.on("POST channels/c2/read", .json(200, "{}"))
        let store = conversationStore(core, channelId: "c2")
        store.isPreview = true
        await store.loadLatest()
        store.isVisible = true
        await store.markReadIfNeeded()
        #expect(core.server.count("POST channels/c2/read") == 0)
        store.isPreview = false
        await store.markReadIfNeeded()
        #expect(core.server.count("POST channels/c2/read") == 1)
    }
}

// MARK: Join, leave, mute

@MainActor
struct BrowseActionTests {
    @Test func joinPostsWithoutBodyThenJoinsTheRoom() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/c2/join", .json(200, #"{"ok":true}"#))
        core.server.on("GET channels/c2/members", .json(200, #"{"humans":[{"id":"u-2","name":"b"}],"agents":[]}"#))
        let realtime = FakeRealtime()
        let workspace = await browseWorkspace(core, realtime: realtime)
        await workspace.channelList.loadMemberCount("c2")
        let store = workspace.conversation(for: ConversationRef(channelId: "c2", title: "Research", kind: .channel))
        #expect(store.isPreview)
        try await workspace.joinChannel("c2")
        let request = try #require(core.server.requests("POST channels/c2/join").first)
        #expect(request.body == nil || request.body?.isEmpty == true)
        #expect(realtime.joins == ["c2"])
        // Home lists it, Browse moves it to Joined, the open preview becomes the conversation.
        #expect(workspace.channelList.channelRows.map(\.id).contains("c2"))
        let groups = workspace.channelList.browseGroups(query: "")
        #expect(!groups.notJoined.map(\.id).contains("c2"))
        #expect(groups.joined.map(\.id).contains("c2"))
        #expect(!store.isPreview)
        #expect(workspace.channelList.memberCount("c2") == 2)
    }

    @Test func joinWithoutOkFailsAndChangesNothing() async {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/c2/join", .json(200, "{}"))
        let realtime = FakeRealtime()
        let workspace = await browseWorkspace(core, realtime: realtime)
        await #expect(throws: (any Error).self) { try await workspace.joinChannel("c2") }
        #expect(workspace.channelList.isPreview("c2"))
        #expect(realtime.joins.isEmpty)
        core.server.on("POST channels/c7/join", .json(403, #"{"error":"forbidden"}"#))
        await #expect(throws: (any Error).self) { try await workspace.joinChannel("c7") }
        #expect(workspace.channelList.isPreview("c7"))
    }

    @Test func readOnlyRefusesJoinAndLeaveWithoutARequest() async {
        let core = TestCore(session: sampleSession())
        let workspace = await browseWorkspace(core, readOnly: true)
        await #expect(throws: StoreError.readOnly) { try await workspace.joinChannel("c2") }
        await #expect(throws: StoreError.readOnly) { try await workspace.leaveChannel("c1") }
        #expect(core.server.count("POST channels/c2/join") == 0)
        #expect(core.server.count("POST channels/c1/leave") == 0)
    }

    @Test func leavingAPublicChannelReturnsItToNotJoined() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/c1/leave", .json(200, #"{"ok":true}"#))
        core.server.on("GET messages/channel/c1", .json(200, pageJSON([])))
        let realtime = FakeRealtime()
        let workspace = await browseWorkspace(core, realtime: realtime)
        _ = workspace.conversation(for: ConversationRef(channelId: "c1", title: "general", kind: .channel))
        #expect(workspace.openConversationIds.contains("c1"))
        try await workspace.leaveChannel("c1")
        #expect(core.server.requests("POST channels/c1/leave").first?.body?.isEmpty ?? true)
        #expect(realtime.leaves == ["c1"])
        #expect(!workspace.channelList.channelRows.map(\.id).contains("c1"))
        #expect(workspace.channelList.browseGroups(query: "").notJoined.map(\.id).contains("c1"))
        // Its store (and pending sends) is dropped.
        #expect(!workspace.openConversationIds.contains("c1"))
    }

    @Test func leavingAPrivateChannelRemovesItAndItsUnread() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/c3/leave", .json(200, #"{"ok":true}"#))
        let workspace = await browseWorkspace(core)
        #expect(workspace.channelList.row(id: "c3")?.priority == .mention)
        try await workspace.leaveChannel("c3")
        #expect(workspace.channelList.channel(id: "c3") == nil)
        #expect(workspace.channelList.mentionCount == 0)
        let groups = workspace.channelList.browseGroups(query: "")
        #expect(!(groups.notJoined + groups.joined).map(\.id).contains("c3"))
    }

    @Test func leaveFailureKeepsTheChannel() async {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/c1/leave", .json(500, "{}"))
        let realtime = FakeRealtime()
        let workspace = await browseWorkspace(core, realtime: realtime)
        await #expect(throws: (any Error).self) { try await workspace.leaveChannel("c1") }
        #expect(workspace.channelList.channelRows.map(\.id).contains("c1"))
        #expect(realtime.leaves.isEmpty)
    }

    @Test func muteIsOptimisticAndRolledBack() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("PATCH channels/c1/notification-settings", replies: [
            .json(200, #"{"activityMuted":true,"activityMuteSupported":true}"#),
            .json(500, "{}"),
        ])
        let workspace = await browseWorkspace(core)
        try await workspace.setChannelMuted("c1", muted: true)
        #expect(core.server.requests("PATCH channels/c1/notification-settings").first?.json == ["activityMuted": true])
        #expect(workspace.channelList.channel(id: "c1")?.activityMuted == true)
        await #expect(throws: (any Error).self) { try await workspace.setChannelMuted("c1", muted: false) }
        #expect(workspace.channelList.channel(id: "c1")?.activityMuted == true)
    }

    @Test func membersAreReadCreatorFirstAndCounted() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels", .json(200, #"[{"id":"c1","name":"general","type":"channel","joined":true,"createdBy":"u-9"}]"#))
        core.server.on("GET channels/dm", .json(200, "[]"))
        core.server.on("GET channels/unread", .json(200, #"{"channels":{},"threadUnread":{}}"#))
        core.server.on("GET channels/c1/members", .json(200, #"{"humans":[{"id":"u-2","name":"amy"},{"id":"u-9","name":"zoe"}],"agents":[{"id":"a1","name":"bot"}]}"#))
        let workspace = Workspace(serverId: "srv-1", currentUserId: "u-1", api: core.api, preferences: .inMemory(readOnly: false), realtime: nil)
        await workspace.channelList.load()
        let members = try await workspace.channelMembers("c1")
        #expect(members.map(\.id) == ["u-9", "u-2", "a1"])
        #expect(workspace.channelList.memberCount("c1") == 3)
    }
}
