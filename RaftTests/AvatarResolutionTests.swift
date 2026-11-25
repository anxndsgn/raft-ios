import Foundation
import Testing
@testable import Raft

// A server like Raft Community: `hideHumansFromMembers` lists only the caller in
// `servers/{id}/members`, messages carry no avatar, and people's photos come from channel rosters
// and member profiles.

private let chrisAvatar = "https://cdn.example.invalid/avatars/users/chris.webp"
private let wenyiAvatar = "https://cdn.example.invalid/avatars/users/wenyi.webp"
private let meAvatar = "https://cdn.example.invalid/avatars/users/me.webp"

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try RaftJSON.decode(T.self, from: Data(json.utf8))
}

private func message(id: String, sender: String, type: String = "user", avatar: String? = nil) throws -> Message {
    let avatarField = avatar.map { #","senderAvatarUrl":"\#($0)""# } ?? ""
    return try decode(Message.self, #"{"id":"\#(id)","senderType":"\#(type)","senderId":"\#(sender)","senderName":"\#(sender)","content":"hi"\#(avatarField)}"#)
}

/// A core whose server hides people: the member list is only `u-1` (the caller).
private func hiddenPeopleCore() -> TestCore {
    let core = TestCore(session: sampleSession())
    core.server.on("GET agents", .json(200, #"[{"id":"a-1","name":"ruby","avatarUrl":"pixel:robot"}]"#))
    core.server.on("GET servers/srv-1/members", .json(200, #"[{"userId":"u-1","name":"me","displayName":"Me","avatarUrl":"\#(meAvatar)"}]"#))
    return core
}

@MainActor
private func loadedDirectory(_ core: TestCore) async -> DirectoryStore {
    let directory = DirectoryStore(api: core.api, serverId: "srv-1")
    await directory.load()
    return directory
}

struct AvatarURLTests {
    @Test func onlyHTTPURLsArePhotos() {
        #expect(Persona.httpURL("https://cdn.raft.build/avatars/users/a.webp") != nil)
        #expect(Persona.httpURL("http://example.invalid/a.png") != nil)
        #expect(Persona.httpURL(nil) == nil)
        #expect(Persona.httpURL("") == nil)
        #expect(Persona.httpURL("pixel:robot") == nil)
        #expect(Persona.httpURL("/avatars/users/a.webp") == nil)
    }

    @Test func firstAvatarSkipsMissingAndNonPhotoCandidates() {
        #expect(DirectoryStore.firstAvatar([nil, "", "pixel:fox", chrisAvatar, wenyiAvatar]) == chrisAvatar)
        #expect(DirectoryStore.firstAvatar([nil, ""]) == nil)
        #expect(DirectoryStore.firstAvatar([]) == nil)
    }

    @Test func messageAndInboxDecodeSenderAvatar() throws {
        #expect(try message(id: "m1", sender: "u-2", avatar: chrisAvatar).senderAvatarUrl == chrisAvatar)
        #expect(try message(id: "m2", sender: "u-2").senderAvatarUrl == nil)
        let item = try decode(InboxItem.self, #"{"kind":"channel","channelId":"c1","lastMessageSenderType":"user","lastMessageSenderId":"u-2","senderAvatarUrl":"\#(chrisAvatar)"}"#)
        #expect(item.senderAvatarUrl == chrisAvatar)
    }

    @Test func avatarNeedsKeepsHumansAndTheirPhotos() {
        var needs = AvatarNeeds()
        needs.add(type: "user", id: "u-2", avatarURL: chrisAvatar)
        needs.add(type: "user", id: "u-3", avatarURL: nil)
        needs.add(type: "agent", id: "a-1", avatarURL: "pixel:robot")
        needs.add(type: "system", id: "system")
        needs.add(type: "user", id: "")
        needs.add(channel: "c1")
        needs.add(channel: "c1")
        needs.add(channel: nil)
        #expect(needs.people == ["u-2", "u-3"])
        #expect(needs.known == ["u-2": chrisAvatar])
        #expect(needs.channels == ["c1"])
    }
}

@MainActor
struct DirectoryAvatarTests {
    @Test func messageRowUsesTheDirectoryLikeTheReplyPreview() async throws {
        let core = hiddenPeopleCore()
        let directory = await loadedDirectory(core)
        let chris = try message(id: "m1", sender: "u-chris")
        // Not in the member list and no avatar in the message: the initials, as the bug showed.
        #expect(directory.persona(for: chris).imageURL == nil)
        // The reply preview's avatar, once seen, also serves the main row.
        let reply = ThreadReplyPreview(messageId: "r1", seq: 1, preview: "hi", senderId: "u-chris", senderType: "user", senderName: "Chris", senderAvatarUrl: chrisAvatar, createdAt: nil)
        directory.learn(replies: [reply])
        #expect(directory.persona(for: chris).imageURL?.absoluteString == chrisAvatar)
        #expect(directory.persona(type: "user", id: "u-chris", name: "Chris").imageURL?.absoluteString == chrisAvatar)
    }

    @Test func resolvesFromTheChannelRosterThenProfiles() async throws {
        let core = hiddenPeopleCore()
        core.server.on("GET channels/c1/members", .json(200, #"""
        {"humans":[{"id":"u-chris","name":"lichenkai","displayName":"Chris","avatarUrl":"\#(chrisAvatar)"},
                   {"id":"u-plain","name":"plain","avatarUrl":null}],
         "agents":[{"id":"a-1","name":"ruby","avatarUrl":"pixel:robot"}],"externalMembers":[]}
        """#))
        core.server.on("GET servers/srv-1/members/u-wenyi/profile", .json(200, #"{"userId":"u-wenyi","name":"huxijin","displayName":"wenyi","avatarUrl":"\#(wenyiAvatar)"}"#))
        core.server.on("GET servers/srv-1/members/u-none/profile", .json(200, #"{"userId":"u-none","name":"none","avatarUrl":null}"#))
        core.server.on("GET servers/srv-1/members/u-gone/profile", .json(404, #"{"error":"Not found","code":"not_found"}"#))
        let directory = await loadedDirectory(core)

        let people = ["u-1", "u-chris", "u-plain", "u-wenyi", "u-none", "u-gone"]
        await directory.resolveAvatars(userIds: people, channelIds: ["c1"])

        #expect(core.server.count("GET channels/c1/members") == 1)
        let profiles = core.server.requests.filter { $0.path.hasSuffix("/profile") }.map(\.path).sorted()
        #expect(profiles == ["servers/srv-1/members/u-gone/profile", "servers/srv-1/members/u-none/profile", "servers/srv-1/members/u-wenyi/profile"],
                "the caller (member list) and the roster's people are not asked for")
        #expect(core.server.requests("GET servers/srv-1/members/u-wenyi/profile").first?.header("X-Server-Id") == "srv-1")

        func image(_ id: String) -> String? { directory.persona(type: "user", id: id, name: id).imageURL?.absoluteString }
        #expect(image("u-1") == meAvatar)
        #expect(image("u-chris") == chrisAvatar)
        #expect(image("u-wenyi") == wenyiAvatar)
        // Truly without a photo: the initials stay.
        #expect(image("u-plain") == nil)
        #expect(image("u-none") == nil)
        #expect(image("u-gone") == nil)

        // Settled: asking again sends nothing.
        let before = core.server.requests.count
        await directory.resolveAvatars(userIds: people, channelIds: ["c1"])
        #expect(core.server.requests.count == before)
    }

    @Test func rosterIsSkippedWhenEveryoneIsKnown() async throws {
        let core = hiddenPeopleCore()
        let directory = await loadedDirectory(core)
        directory.learn(avatars: [(id: "u-chris", url: chrisAvatar)])
        await directory.resolveAvatars(userIds: ["u-1", "u-chris"], channelIds: ["c1"])
        #expect(core.server.count("GET channels/c1/members") == 0)
        #expect(!core.server.requests.contains { $0.path.hasSuffix("/profile") })
    }

    @Test func failedRequestsAreAskedAgain() async throws {
        let core = hiddenPeopleCore()
        core.server.on("GET channels/c1/members", replies: [.json(500, #"{"error":"boom"}"#), .json(200, #"{"humans":[{"id":"u-chris","name":"c","avatarUrl":"\#(chrisAvatar)"}]}"#)])
        core.server.on("GET servers/srv-1/members/u-chris/profile", replies: [.json(500, #"{"error":"boom"}"#), .json(200, #"{"userId":"u-chris","name":"c","avatarUrl":null}"#)])
        let directory = await loadedDirectory(core)

        await directory.resolveAvatars(userIds: ["u-chris"], channelIds: ["c1"])
        #expect(directory.persona(type: "user", id: "u-chris", name: "Chris").imageURL == nil)

        await directory.resolveAvatars(userIds: ["u-chris"], channelIds: ["c1"])
        #expect(core.server.count("GET channels/c1/members") == 2)
        #expect(directory.persona(type: "user", id: "u-chris", name: "Chris").imageURL?.absoluteString == chrisAvatar)
    }

    @Test func nothingIsAskedBeforeTheDirectoryLoads() async throws {
        let core = hiddenPeopleCore()
        let directory = DirectoryStore(api: core.api, serverId: "srv-1")
        await directory.resolveAvatars(userIds: ["u-chris"], channelIds: ["c1"])
        #expect(core.server.requests.isEmpty)
    }

    @Test func payloadAvatarWinsAndEmptyOneFallsBack() async throws {
        let core = hiddenPeopleCore()
        let directory = await loadedDirectory(core)
        directory.learn(avatars: [(id: "u-chris", url: chrisAvatar)])
        #expect(directory.persona(type: "user", id: "u-chris", name: "Chris", avatarURL: wenyiAvatar).imageURL?.absoluteString == wenyiAvatar)
        // Search sends null / empty avatars: the learned photo still shows.
        #expect(directory.persona(type: "user", id: "u-chris", name: "Chris", avatarURL: "").imageURL?.absoluteString == chrisAvatar)
        #expect(directory.persona(type: "user", id: "u-chris", name: "Chris", avatarURL: nil).imageURL?.absoluteString == chrisAvatar)
        // A payload's null never erases a learned photo.
        directory.learn(avatars: [(id: "u-chris", url: nil)])
        #expect(directory.avatarURL(forUser: "u-chris") == chrisAvatar)
    }

    @Test func agentsKeepTheirPixelFaces() async throws {
        let core = hiddenPeopleCore()
        let directory = await loadedDirectory(core)
        let persona = directory.persona(for: try message(id: "m1", sender: "a-1", type: "agent"))
        #expect(persona.kind == .agent)
        #expect(persona.pixelKey == "robot")
        #expect(persona.imageURL == nil)
    }
}
