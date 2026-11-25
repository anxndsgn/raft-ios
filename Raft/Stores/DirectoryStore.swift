import Foundation
import Observation

/// Someone `@` can name in the composer.
struct MentionCandidate: Identifiable, Hashable, Sendable {
    var id: String
    /// `user` or `agent` (the send body's mention type).
    var type: String
    var name: String
    var handle: String
    var persona: Persona

    var isAgent: Bool { type == "agent" }
}

/// The people and agents of one server: avatars, runtimes, presence and mention candidates.
/// `GET agents` and `GET servers/{id}/members`, read when the workspace opens and on foreground.
@MainActor
@Observable
final class DirectoryStore {
    private(set) var agents: [String: AgentProfile] = [:]
    private(set) var members: [String: ServerMember] = [:]
    private(set) var loaded = false
    /// People's avatars learned beside the member list, by user id: from channel rosters, member
    /// profiles and payloads that carry one. `""` marks a person known to have none. A server
    /// with `hideHumansFromMembers` (Raft Community) lists only the caller in
    /// `servers/{id}/members`, and messages carry no avatar, so this is where most people's
    /// faces come from there.
    private(set) var learnedAvatars: [String: String] = [:]

    @ObservationIgnored let serverId: String
    @ObservationIgnored private let api: RaftAPI?
    /// Channels whose roster was read (or is being read) for avatars.
    @ObservationIgnored private var rostersAsked: Set<String> = []
    /// People whose profile was asked for (or is being asked for).
    @ObservationIgnored private var profilesAsked: Set<String> = []
    /// Profile requests at once.
    @ObservationIgnored var profileConcurrency = 4

    init(api: RaftAPI?, serverId: String) {
        self.api = api
        self.serverId = serverId
    }

    func load() async {
        guard let api else { return }
        let serverId = self.serverId
        async let agentsResult = captureResult { try await api.agents() }
        async let membersResult = captureResult { try await api.members(serverId: serverId) }
        let (loadedAgents, loadedMembers) = await (agentsResult, membersResult)
        if case .success(let list) = loadedAgents {
            agents = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if case .success(let list) = loadedMembers {
            members = Dictionary(list.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        }
        loaded = true
    }

    /// Both lists in parallel, applied together only when both arrive (New message, 28: people
    /// and agents must not appear one list after the other). Throws the first failure.
    func reloadPeople() async throws {
        guard let api else { return }
        let serverId = self.serverId
        async let agentsResult = captureResult { try await api.agents() }
        async let membersResult = captureResult { try await api.members(serverId: serverId) }
        let (loadedAgents, loadedMembers) = await (agentsResult, membersResult)
        let agentList = try loadedAgents.get()
        let memberList = try loadedMembers.get()
        agents = Dictionary(agentList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        members = Dictionary(memberList.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        loaded = true
    }

    /// People and agents are held (from an earlier load).
    var hasPeople: Bool { !agents.isEmpty || !members.isEmpty }

    func agent(_ id: String) -> AgentProfile? { agents[id] }

    /// The avatar of a message's sender.
    func persona(for message: Message) -> Persona {
        persona(type: message.senderType, id: message.senderId, name: message.senderName, avatarURL: message.senderAvatarUrl)
    }

    func persona(type: String, id: String, name: String?, avatarURL: String? = nil) -> Persona {
        if type == "agent" {
            let agent = agents[id]
            let display = agent?.visibleName ?? name ?? L10n.t("thread_agent_typing_agent_fallback", "Agent")
            let key = agent?.pixelKey ?? Self.pixelKey(avatarURL)
            return .agent(id: id, name: display, pixelKey: key, presence: Presence(activity: agent?.activity), runtime: agent?.runtimeName)
        }
        let member = members[id]
        let display = [member?.displayName, member?.name, name].compactMap { $0 }.first { !$0.isEmpty } ?? "?"
        return .human(id: id, name: display, avatarURL: self.avatarURL(forUser: id, given: avatarURL))
    }

    // MARK: People's avatars

    /// A person's photo: the one the payload gave, else the member list's, else a learned one.
    /// Only `http(s)` URLs count; nil when none is known.
    func avatarURL(forUser id: String, given: String? = nil) -> String? {
        Self.firstAvatar([given, members[id]?.avatarUrl, learnedAvatars[id]])
    }

    /// The first candidate that is a usable photo URL.
    nonisolated static func firstAvatar(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            if let candidate, Persona.httpURL(candidate) != nil { return candidate }
        }
        return nil
    }

    /// The person's avatar is settled: known, known to be absent, or the member list has them.
    func knowsAvatar(of id: String) -> Bool {
        avatarURL(forUser: id) != nil || learnedAvatars[id] != nil || members[id] != nil
    }

    /// Avatars a payload carried (reply previews, Activity rows, DM peers). A missing value says
    /// nothing (search results send null for everyone), so only photos are kept.
    func learn(avatars: [(id: String, url: String?)]) {
        var found: [String: String] = [:]
        for entry in avatars where !entry.id.isEmpty {
            if let url = Self.firstAvatar([entry.url]) { found[entry.id] = url }
        }
        record(found)
    }

    /// A channel roster is authoritative for the people it lists: their photo, or none.
    func learn(roster: [ChannelMember]) {
        var found: [String: String] = [:]
        for member in roster where member.kind == .human {
            found[member.id] = Self.firstAvatar([member.avatarUrl]) ?? ""
        }
        record(found)
    }

    /// The reply previews under messages (`latestReplies`) carry their senders' avatars.
    func learn(replies: [ThreadReplyPreview]) {
        learn(avatars: replies.filter { $0.senderType != "agent" }.map { ($0.senderId, $0.senderAvatarUrl) })
    }

    /// Settles the avatars of `userIds` the directory does not know yet: the rosters of
    /// `channelIds` first (one request covers a channel's people), then each person still unknown
    /// by their member profile. Each channel and person is asked once; a failed request may be
    /// asked again later. Waits for the first directory load (the member list may already know).
    func resolveAvatars(userIds: [String], channelIds: [String] = []) async {
        guard let api, loaded else { return }
        var missing = Set(userIds.filter { !$0.isEmpty && !knowsAvatar(of: $0) })
        guard !missing.isEmpty else { return }
        var seenChannels = Set<String>()
        for channelId in channelIds where !channelId.isEmpty && seenChannels.insert(channelId).inserted {
            guard !missing.isEmpty, !rostersAsked.contains(channelId) else { continue }
            rostersAsked.insert(channelId)
            do {
                learn(roster: try await api.channelMembers(channelId: channelId))
            } catch {
                rostersAsked.remove(channelId)
            }
            missing = missing.filter { !knowsAvatar(of: $0) }
        }
        let asking = missing.subtracting(profilesAsked).sorted()
        guard !asking.isEmpty else { return }
        profilesAsked.formUnion(asking)
        let serverId = self.serverId
        let limit = max(profileConcurrency, 1)
        // nil: the request failed (ask again later); "": the person has no photo (or left).
        let answers: [(String, String?)] = await withTaskGroup(of: (String, String?).self) { group in
            var results: [(String, String?)] = []
            var index = 0
            while index < asking.count || !group.isEmpty {
                while index < asking.count, index - results.count < limit {
                    let id = asking[index]
                    index += 1
                    group.addTask {
                        do {
                            let profile = try await api.memberProfile(serverId: serverId, userId: id)
                            return (id, DirectoryStore.firstAvatar([profile?.avatarUrl]) ?? "")
                        } catch {
                            return (id, nil)
                        }
                    }
                }
                if let result = await group.next() { results.append(result) }
            }
            return results
        }
        var found: [String: String] = [:]
        for (id, url) in answers {
            if let url { found[id] = url } else { profilesAsked.remove(id) }
        }
        record(found)
    }

    /// Merges learned avatars, publishing only a real change.
    private func record(_ found: [String: String]) {
        var next = learnedAvatars
        for (id, url) in found { next[id] = url }
        if next != learnedAvatars { learnedAvatars = next }
    }

    static func pixelKey(_ avatarURL: String?) -> String? {
        guard let avatarURL, avatarURL.hasPrefix("pixel:") else { return nil }
        return String(avatarURL.dropFirst("pixel:".count))
    }

    /// Agents first, then people; both by name.
    var mentionCandidates: [MentionCandidate] {
        let agentRows = agents.values
            .filter { ($0.status ?? "") != "deleted" }
            .map { agent in
                MentionCandidate(
                    id: agent.id, type: "agent", name: agent.visibleName, handle: agent.name,
                    persona: .agent(id: agent.id, name: agent.visibleName, pixelKey: agent.pixelKey, presence: Presence(activity: agent.activity), runtime: agent.runtimeName)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let people = members.values
            .filter { ($0.membershipStatus ?? "active") == "active" }
            .map { member in
                let name = [member.displayName, member.name].compactMap { $0 }.first { !$0.isEmpty } ?? member.userId
                return MentionCandidate(id: member.userId, type: "user", name: name, handle: member.name, persona: .human(id: member.userId, name: name, avatarURL: member.avatarUrl))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return agentRows + people
    }

    /// Prefix match on name words and handle, at most `limit`.
    func mentionMatches(_ query: String, excluding userId: String?, limit: Int = 5) -> [MentionCandidate] {
        let needle = query.lowercased()
        return mentionCandidates
            .filter { $0.id != userId }
            .filter { candidate in
                guard !needle.isEmpty else { return true }
                if candidate.handle.lowercased().hasPrefix(needle) { return true }
                return candidate.name.lowercased().split(separator: " ").contains { $0.hasPrefix(needle) }
                    || candidate.name.lowercased().hasPrefix(needle)
            }
            .prefix(limit)
            .map { $0 }
    }

    #if DEBUG
    func debugSeed(agents: [AgentProfile], members: [ServerMember]) {
        self.agents = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.members = Dictionary(members.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        loaded = true
    }
    #endif
}

/// Home's extras beside the list: the Saved count, pinned conversations and the server's
/// notification level.
@MainActor
@Observable
final class HomeExtrasStore {
    /// The Saved chip's number (the saved store's total).
    var savedCount: Int? { savedStore?.total }
    private(set) var pinned: [SidebarOrder.PinnedRef] = []
    private(set) var notificationLevel: NotificationLevel?
    /// The newest unread message per conversation (Unread cards), from Activity's unread rows;
    /// keyed by channel id (thread rows by their parent channel).
    private(set) var previews: [String: UnreadPreview] = [:]
    var errorMessage: String?

    struct UnreadPreview: Hashable, Sendable {
        var sender: String?
        var text: String?
        /// A followed thread's reply: the thread's root text.
        var threadTitle: String?
    }

    @ObservationIgnored let serverId: String
    @ObservationIgnored private let api: RaftAPI?
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let savedStore: SavedStore?

    init(api: RaftAPI?, serverId: String, preferences: AppPreferences, saved: SavedStore? = nil) {
        self.api = api
        self.serverId = serverId
        self.preferences = preferences
        savedStore = saved
    }

    func load() async {
        guard let api else { return }
        let serverId = self.serverId
        async let savedResult = captureResult { try await api.saved(limit: 1) }
        async let orderResult = captureResult { try await api.sidebarOrder(serverId: serverId) }
        async let levelResult = captureResult { try await api.notificationLevels() }
        let (savedPage, order, level) = await (savedResult, orderResult, levelResult)
        if case .success(let page) = savedPage { savedStore?.absorbTotal(page) }
        if case .success(let value) = order { pinned = value.pinned }
        if case .success(let value) = level { notificationLevel = value.server }
    }

    func loadPreviews() async {
        guard let api, let page = try? await api.inbox(filter: "unread", limit: 50, offset: 0) else { return }
        var next: [String: UnreadPreview] = [:]
        for item in page.items {
            if item.isSubConversation {
                guard let parent = item.parentChannelId, next[parent] == nil else { continue }
                next[parent] = UnreadPreview(sender: item.senderName, text: item.preview, threadTitle: item.parentMessagePreview ?? "")
            } else if let channelId = item.channelId {
                next[channelId] = UnreadPreview(sender: item.senderName, text: item.preview)
            }
        }
        previews = next
    }

    /// Writes the server level (refused in read-only mode; the menu shows the error).
    func setNotificationLevel(_ level: NotificationLevel) async {
        guard !preferences.readOnly else {
            errorMessage = StoreError.readOnly.errorDescription
            return
        }
        guard let api else { return }
        let previous = notificationLevel
        notificationLevel = level
        do {
            try await api.setServerNotificationLevel(serverId: serverId, level: level)
        } catch {
            notificationLevel = previous
            errorMessage = ErrorText.describe(error)
        }
    }

    #if DEBUG
    func debugSeed(pinned: [SidebarOrder.PinnedRef], level: NotificationLevel?, previews: [String: UnreadPreview] = [:]) {
        self.previews = previews
        self.pinned = pinned
        notificationLevel = level
    }
    #endif
}
