import Foundation
import Observation

/// What this person saved on this server (§13): the ids behind the chat's marks and the
/// long-press Save / Remove item, the count on Home's chip, and the Saved list (30). Saving and
/// removing are optimistic; a failure puts back the last state the server confirmed.
@MainActor
@Observable
final class SavedStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// The first page failed (`offline`: no connection).
        case failed(offline: Bool)
    }

    enum MorePhase: Equatable {
        case idle
        case loading
        case failed
    }

    /// A finished change for the screens to confirm (haptic, VoiceOver, toast).
    struct Feedback: Equatable {
        enum Kind: Equatable {
            case saved
            case removed
            case saveFailed
            case removeFailed
            case readOnly
            /// A row whose message is gone (13.3): removed from the list.
            case unavailable
        }

        let serial: Int
        let kind: Kind
    }

    private(set) var savedIds: Set<String> = []
    /// `globalTotal`, adjusted by local changes; nil until known.
    private(set) var total: Int?
    private(set) var entries: [SavedEntry] = []
    private(set) var phase: Phase = .idle
    private(set) var hasMore = false
    private(set) var more: MorePhase = .idle
    private(set) var feedback: Feedback?

    @ObservationIgnored let pageSize = 30
    @ObservationIgnored private let api: RaftAPI?
    @ObservationIgnored private let preferences: AppPreferences
    /// The next page's offset: entries received as sent (before dedupe).
    @ObservationIgnored private var rawOffset = 0
    @ObservationIgnored private var firstPageIds: Set<String> = []
    /// The last state the server confirmed, per message.
    @ObservationIgnored private var confirmed: [String: Bool] = [:]
    /// The state last asked for while a request runs or is due.
    @ObservationIgnored private var desired: [String: Bool] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Rows taken out of the list by a removal, for a rollback to put back where they were.
    @ObservationIgnored private var removedRows: [String: (entry: SavedEntry, index: Int)] = [:]
    @ObservationIgnored private var feedbackSerial = 0

    init(api: RaftAPI?, preferences: AppPreferences) {
        self.api = api
        self.preferences = preferences
    }

    func isSaved(_ messageId: String) -> Bool { savedIds.contains(messageId) }

    // MARK: Check (12c)

    /// Which of these messages are saved (`channels/saved/check`, 200 ids per request). Ids of
    /// this device's unsent messages, and messages with a change on the way, are left out.
    func check(_ messageIds: [String]) async {
        guard let api else { return }
        var seen = Set<String>()
        let ids = messageIds.filter { id in
            !id.isEmpty && !id.hasPrefix("ios-") && desired[id] == nil && !inFlight.contains(id) && seen.insert(id).inserted
        }
        for start in stride(from: 0, to: ids.count, by: RaftAPI.savedCheckLimit) {
            let chunk = Array(ids[start..<min(start + RaftAPI.savedCheckLimit, ids.count)])
            // A failed check keeps what is shown (the error is not the person's to act on).
            guard let saved = try? await api.checkSaved(ids: chunk) else { continue }
            let set = Set(saved)
            for id in chunk where desired[id] == nil && !inFlight.contains(id) {
                let isSaved = set.contains(id)
                confirmed[id] = isSaved
                if isSaved { savedIds.insert(id) } else { savedIds.remove(id) }
            }
        }
    }

    // MARK: List (30)

    /// The first page; merged into what is held (no skeleton when something is shown).
    func refresh() async {
        guard let api, !isFrozen else { return }
        if entries.isEmpty, phase != .loaded { phase = .loading }
        do {
            let page = try await api.saved(limit: pageSize, offset: 0)
            absorbFirstPage(page)
        } catch {
            if phase != .loaded { phase = .failed(offline: Self.isTransport(error)) }
        }
    }

    func loadMore() async {
        guard let api, !isFrozen, phase == .loaded, hasMore, more != .loading else { return }
        more = .loading
        do {
            let page = try await api.saved(limit: pageSize, offset: rawOffset)
            rawOffset += page.rawCount
            let held = Set(entries.map(\.id))
            let fresh = Self.unique(page.saved).filter { !held.contains($0.id) && desired[$0.id] != false }
            entries.append(contentsOf: fresh)
            noteSaved(fresh)
            hasMore = page.hasMore && page.rawCount > 0
            more = .idle
        } catch {
            more = .failed
        }
    }

    /// The count from Home's `channels/saved?limit=1`.
    func absorbTotal(_ page: SavedPage) {
        guard desired.isEmpty else { return }
        total = page.total
    }

    private func absorbFirstPage(_ page: SavedPage) {
        let fresh = Self.unique(page.saved).filter { desired[$0.id] != false }
        let freshIds = Set(fresh.map(\.id))
        if rawOffset <= page.rawCount || phase != .loaded {
            entries = fresh
            rawOffset = page.rawCount
            hasMore = page.hasMore
        } else {
            // Later pages stay; the old first page's rows gone from the new one were removed.
            let rest = entries.filter { !freshIds.contains($0.id) && !firstPageIds.contains($0.id) }
            entries = fresh + rest
        }
        firstPageIds = freshIds
        noteSaved(fresh)
        if desired.isEmpty { total = page.total }
        phase = .loaded
    }

    private func noteSaved(_ list: [SavedEntry]) {
        for entry in list where desired[entry.id] == nil {
            confirmed[entry.id] = true
            savedIds.insert(entry.id)
        }
    }

    // MARK: Save and remove (13.2)

    /// Saves or removes at once on screen, then asks the server: one request per message at a
    /// time, followed by another when the asked state changed meanwhile. A failure goes back to
    /// the last confirmed state (a removed row returns to its place). `entry` is the list row,
    /// when the change comes from the list.
    func setSaved(_ messageId: String, _ saved: Bool, entry: SavedEntry? = nil) async {
        guard !preferences.readOnly else {
            post(.readOnly)
            return
        }
        guard api != nil, !messageId.isEmpty else { return }
        let shown = isSaved(messageId)
        if confirmed[messageId] == nil, !inFlight.contains(messageId) { confirmed[messageId] = shown }
        if shown != saved { show(messageId, saved: saved, entry: entry) }
        desired[messageId] = saved
        guard !inFlight.contains(messageId) else { return }
        await send(messageId)
    }

    func toggle(_ messageId: String) async {
        await setSaved(messageId, !isSaved(messageId))
    }

    private func send(_ id: String) async {
        guard let api else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        var sentAny = false
        while let want = desired[id], want != confirmed[id] {
            do {
                if want {
                    try await api.saveMessage(id: id)
                } else {
                    try await api.unsaveMessage(id: id)
                }
                confirmed[id] = want
                sentAny = true
            } catch {
                rollBack(id)
                post(want ? .saveFailed : .removeFailed)
                return
            }
        }
        let final = confirmed[id] ?? false
        desired[id] = nil
        if !final { removedRows[id] = nil }
        if sentAny { post(final ? .saved : .removed) }
    }

    private func rollBack(_ id: String) {
        desired[id] = nil
        let back = confirmed[id] ?? false
        if isSaved(id) != back { show(id, saved: back, entry: nil) }
        if back { removedRows[id] = nil }
    }

    /// The on-screen state: the id, the count, and the list row.
    private func show(_ id: String, saved: Bool, entry: SavedEntry?) {
        if saved {
            if savedIds.insert(id).inserted { total = total.map { $0 + 1 } }
            if !entries.contains(where: { $0.id == id }) {
                if let removed = removedRows.removeValue(forKey: id) {
                    entries.insert(removed.entry, at: min(removed.index, entries.count))
                } else if let entry {
                    entries.insert(entry, at: 0)
                }
            }
        } else {
            if savedIds.remove(id) != nil { total = total.map { max(0, $0 - 1) } }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                removedRows[id] = (entries[index], index)
                entries.remove(at: index)
            }
        }
    }

    /// 13.3: the row's message is gone (`messages/context` 404 / 403). The row goes for good and
    /// the server forgets it (a failure is not rolled back).
    func removeUnavailable(_ messageId: String) async {
        show(messageId, saved: false, entry: nil)
        removedRows[messageId] = nil
        confirmed[messageId] = false
        post(.unavailable)
        guard let api, !preferences.readOnly else { return }
        try? await api.unsaveMessage(id: messageId)
    }

    private func post(_ kind: Feedback.Kind) {
        feedbackSerial += 1
        feedback = Feedback(serial: feedbackSerial, kind: kind)
    }

    private static func unique(_ list: [SavedEntry]) -> [SavedEntry] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    private var isFrozen: Bool {
        #if DEBUG
        frozen
        #else
        false
        #endif
    }

    private static func isTransport(_ error: Error) -> Bool {
        if case .transport = error as? APIError { return true }
        return error is URLError
    }

    #if DEBUG
    /// Preview gallery: a seeded list stays as seeded (every request fails offline there).
    @ObservationIgnored private var frozen = false

    func debugSeed(phase: Phase, entries: [SavedEntry] = [], total: Int? = nil, savedIds: Set<String> = [], hasMore: Bool = false) {
        frozen = phase != .idle
        self.phase = phase
        self.entries = entries
        self.total = total ?? entries.count
        self.savedIds = savedIds.union(entries.map(\.id))
        self.hasMore = hasMore
        rawOffset = entries.count
        firstPageIds = Set(entries.map(\.id))
    }
    #endif
}
