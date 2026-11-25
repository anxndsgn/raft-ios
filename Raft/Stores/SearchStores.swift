import Foundation
import Observation

// MARK: New message (28): open or create a DM

/// Who a DM is with: a person (`user`) or an agent (`agent`), as `channels/dm` rows name them.
struct DirectMessagePeer: Hashable, Sendable {
    var type: String
    var id: String

    var isAgent: Bool { type == "agent" }
}

enum DirectMessageOpenError: Error, Equatable {
    /// No answer within `DirectMessageOpens.timeout`.
    case timedOut
    /// Offline: the request is not sent.
    case offline
}

/// One `POST channels/dm` per server + peer at a time, process-wide (the old app's
/// `RaftDirectMessageOpens`: on a slow network repeated taps sent one request each). A second
/// open of the same peer waits for the first one's answer.
@MainActor
enum DirectMessageOpens {
    static let timeout: Duration = .seconds(15)
    private static var pending: [String: Task<DirectMessageChannel, Error>] = [:]

    static func open(key: String, _ work: @escaping @Sendable () async throws -> DirectMessageChannel) async throws -> DirectMessageChannel {
        if let running = pending[key] { return try await running.value }
        let task = Task { try await withTimeout(timeout, work) }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }

    /// `work`'s value, or `DirectMessageOpenError.timedOut` after `limit`.
    nonisolated static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw DirectMessageOpenError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DirectMessageOpenError.timedOut }
            return first
        }
    }
}

extension Workspace {
    /// The DM with `peer`: Home's when it lists one (no request), else `POST channels/dm` (deduped
    /// per peer, 15s), put on top of Home's list. Refused offline and in read-only mode.
    func openDirectMessage(with peer: DirectMessagePeer) async throws -> DirectMessageChannel {
        if let existing = channelList.existingDirectMessage(peerType: peer.type, peerId: peer.id) { return existing }
        guard !isOffline else { throw DirectMessageOpenError.offline }
        guard !preferences.readOnly else { throw StoreError.readOnly }
        let api = self.api
        let dm = try await DirectMessageOpens.open(key: "\(serverId)|\(peer.type)|\(peer.id)") {
            try await api.openDirectMessage(peerType: peer.type, peerId: peer.id)
        }
        channelList.insertDirectMessage(dm)
        return dm
    }
}

// MARK: Message search (29)

/// Recent message searches, on this device only, per server and account (the old app's
/// `SearchPersonalizationRepository`): newest first, at most 15 kept.
@MainActor
@Observable
final class RecentSearches {
    static let limit = 15
    /// Rows the page shows.
    static let shown = 8

    private(set) var items: [String] = []
    @ObservationIgnored private let key: String
    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults` nil: kept in memory only (previews).
    init(serverId: String, userId: String, defaults: UserDefaults? = .standard) {
        key = "raft.search.recent.\(serverId).\(userId)"
        self.defaults = defaults
        items = defaults?.stringArray(forKey: key) ?? []
    }

    /// Moves `query` to the front (same text ignoring case and outer spaces counts as one).
    func record(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        items.removeAll { $0.caseInsensitiveCompare(clean) == .orderedSame }
        items.insert(clean, at: 0)
        if items.count > Self.limit { items = Array(items.prefix(Self.limit)) }
        save()
    }

    func remove(_ query: String) {
        items.removeAll { $0 == query }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        defaults?.set(items, forKey: key)
    }

    #if DEBUG
    func debugSeed(_ queries: [String]) {
        items = queries
    }
    #endif
}

/// The message search page: query → debounced `GET messages/search`, paging, recent searches.
@MainActor
@Observable
final class MessageSearchStore {
    enum Phase: Equatable {
        /// Under two characters: recent searches show.
        case idle
        /// The first page is on its way (skeleton).
        case loading
        case loaded
        case failed(offline: Bool)
    }

    static let minimumLength = 2
    static let maximumLength = 200
    static let pageSize = 30
    static let debounce: Duration = .milliseconds(300)

    /// The search field's text.
    var text = ""
    private(set) var phase: Phase = .idle
    /// The trimmed query `results` belong to.
    private(set) var query = ""
    private(set) var results: [MessageSearchResult] = []
    private(set) var canLoadMore = false
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false
    /// The page was sorted newest first: too many matches to rank (`relevanceFallback`).
    private(set) var isRelevanceFallback = false
    /// The any-word fallback was skipped (`relaxedSkipped`): an empty page says why.
    private(set) var isRelaxedSkipped = false
    /// Counts first pages shown (VoiceOver says when the results change).
    private(set) var resultsVersion = 0
    let recent: RecentSearches

    @ObservationIgnored private let api: RaftAPI?
    @ObservationIgnored private let isOffline: @MainActor () -> Bool
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?

    init(api: RaftAPI?, recent: RecentSearches, isOffline: @escaping @MainActor () -> Bool = { false }) {
        self.api = api
        self.recent = recent
        self.isOffline = isOffline
    }

    /// The field's text, trimmed and capped at 200 characters.
    var trimmedText: String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumLength))
    }

    var showsRecent: Bool { trimmedText.count < Self.minimumLength }

    // MARK: Input

    /// The field changed: under two characters clears the results; otherwise a search runs after
    /// the debounce (the old results give way to the skeleton at once).
    func textChanged() {
        let next = trimmedText
        guard next.count >= Self.minimumLength else {
            cancel()
            query = ""
            results = []
            phase = .idle
            return
        }
        if next == query, phase != .idle { return }
        run(next, after: Self.debounce)
    }

    /// Return: search now and remember the query.
    func submit() {
        let next = trimmedText
        guard next.count >= Self.minimumLength else { return }
        recent.record(next)
        if next != query || !isSettled { run(next, after: nil) }
    }

    /// A recent search tapped: fill it in and search now.
    func searchAgain(_ saved: String) {
        text = saved
        let next = trimmedText
        guard next.count >= Self.minimumLength else { return }
        recent.record(next)
        run(next, after: nil)
    }

    /// A result was opened: its query becomes a recent search.
    func noteOpened() {
        guard query.count >= Self.minimumLength else { return }
        recent.record(query)
    }

    func retry() {
        guard query.count >= Self.minimumLength else { return }
        run(query, after: nil)
    }

    /// Loaded or loading (not failed): Return does not search the same text again.
    private var isSettled: Bool {
        switch phase {
        case .loaded, .loading: true
        case .idle, .failed: false
        }
    }

    private func cancel() {
        searchTask?.cancel()
        searchTask = nil
        moreTask?.cancel()
        moreTask = nil
        isLoadingMore = false
        loadMoreFailed = false
    }

    // MARK: Loading

    private func run(_ next: String, after delay: Duration?) {
        cancel()
        query = next
        results = []
        canLoadMore = false
        nextCursor = nil
        isRelevanceFallback = false
        isRelaxedSkipped = false
        phase = .loading
        searchTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.loadFirst(next)
        }
    }

    private func loadFirst(_ next: String) async {
        guard let api else { return }
        guard !isOffline() else {
            phase = .failed(offline: true)
            return
        }
        do {
            let page = try await api.searchMessages(query: next, limit: Self.pageSize, offset: 0)
            guard !Task.isCancelled, next == query else { return }
            results = Self.unique(page.results)
            absorb(page)
            phase = .loaded
            resultsVersion += 1
        } catch {
            guard !Task.isCancelled, next == query else { return }
            if let apiError = error as? APIError, apiError.status == 400 {
                // INVALID_QUERY (too long, nothing searchable): no results, not an error (§12.2).
                results = []
                canLoadMore = false
                phase = .loaded
                resultsVersion += 1
                return
            }
            phase = .failed(offline: Self.isTransport(error) || isOffline())
        }
    }

    /// The next page: near the end of the list, or `retrying` from the Retry line under it (a
    /// failed page is not asked for again by scrolling alone).
    func loadMore(retrying: Bool = false) {
        guard phase == .loaded, canLoadMore, !isLoadingMore, retrying || !loadMoreFailed, let api else { return }
        let current = query
        let offset = results.count
        let cursor = nextCursor
        isLoadingMore = true
        loadMoreFailed = false
        moreTask = Task { [weak self] in
            do {
                let page = try await api.searchMessages(query: current, limit: Self.pageSize, offset: offset, cursor: cursor)
                guard let self, !Task.isCancelled, current == self.query else { return }
                let known = Set(self.results.map(\.id))
                self.results += Self.unique(page.results).filter { !known.contains($0.id) }
                self.absorb(page)
                self.isLoadingMore = false
            } catch {
                guard let self, !Task.isCancelled, current == self.query else { return }
                self.isLoadingMore = false
                self.loadMoreFailed = true
            }
        }
    }

    private func absorb(_ page: MessageSearchPage) {
        canLoadMore = page.canContinue && !page.results.isEmpty
        nextCursor = page.nextCursor
        if page.relevanceFallback == "too_broad" { isRelevanceFallback = true }
        if page.relaxedSkipped == "too_broad" { isRelaxedSkipped = true }
    }

    private static func unique(_ results: [MessageSearchResult]) -> [MessageSearchResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }

    private static func isTransport(_ error: Error) -> Bool {
        if case .transport = error as? APIError { return true }
        return error is URLError
    }

    #if DEBUG
    func debugSeed(text: String, phase: Phase, results: [MessageSearchResult] = [], relaxedSkipped: Bool = false) {
        self.text = text
        query = trimmedText
        self.phase = phase
        self.results = results
        isRelaxedSkipped = relaxedSkipped
    }
    #endif
}
