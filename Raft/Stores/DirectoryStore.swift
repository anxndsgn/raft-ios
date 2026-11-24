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

    @ObservationIgnored let serverId: String
    @ObservationIgnored private let api: RaftAPI?

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

    func agent(_ id: String) -> AgentProfile? { agents[id] }

    /// The avatar of a message's sender.
    func persona(for message: Message) -> Persona {
        persona(type: message.senderType, id: message.senderId, name: message.senderName)
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
        return .human(id: id, name: display, avatarURL: member?.avatarUrl ?? avatarURL)
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
    private(set) var savedCount: Int?
    private(set) var saved: [SavedEntry] = []
    private(set) var savedPhase: LoadPhase = .idle
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

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @ObservationIgnored let serverId: String
    @ObservationIgnored private let api: RaftAPI?
    @ObservationIgnored private let preferences: AppPreferences

    init(api: RaftAPI?, serverId: String, preferences: AppPreferences) {
        self.api = api
        self.serverId = serverId
        self.preferences = preferences
    }

    func load() async {
        guard let api else { return }
        let serverId = self.serverId
        async let savedResult = captureResult { try await api.saved(limit: 1) }
        async let orderResult = captureResult { try await api.sidebarOrder(serverId: serverId) }
        async let levelResult = captureResult { try await api.notificationLevels() }
        let (savedPage, order, level) = await (savedResult, orderResult, levelResult)
        if case .success(let page) = savedPage { savedCount = page.total }
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

    func loadSaved() async {
        guard let api else { return }
        if saved.isEmpty { savedPhase = .loading }
        do {
            let page = try await api.saved(limit: 50)
            saved = page.saved
            savedCount = page.total
            savedPhase = .loaded
        } catch {
            if saved.isEmpty { savedPhase = .failed(ErrorText.describe(error)) }
        }
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
    func debugSeed(savedCount: Int?, pinned: [SidebarOrder.PinnedRef], level: NotificationLevel?, saved: [SavedEntry] = [], previews: [String: UnreadPreview] = [:]) {
        self.previews = previews
        self.savedCount = savedCount
        self.pinned = pinned
        notificationLevel = level
        self.saved = saved
        savedPhase = .loaded
    }
    #endif
}
