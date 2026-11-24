import Foundation
import Observation

/// App preferences that change what the app writes to the server.
@MainActor
@Observable
final class AppPreferences {
    private static let readOnlyKey = "raft.readOnly"

    /// No sends, reactions, thread creation or read receipts reach the server. DEBUG builds start
    /// read-only (they run against real accounts while the UI is built); Release is never read-only.
    var readOnly: Bool {
        didSet { defaults.set(readOnly, forKey: Self.readOnlyKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        readOnly = defaults.object(forKey: Self.readOnlyKey) as? Bool ?? true
        #else
        readOnly = false
        #endif
    }

    /// A preferences object that writes nowhere (tests, previews).
    static func inMemory(readOnly: Bool) -> AppPreferences {
        let suite = "raft.preferences.\(UUID().uuidString)"
        let prefs = AppPreferences(defaults: UserDefaults(suiteName: suite) ?? .standard)
        prefs.readOnly = readOnly
        return prefs
    }
}

enum StoreError: Error, Equatable, LocalizedError {
    /// A write was asked for while `AppPreferences.readOnly` is on.
    case readOnly
    case notReady

    var errorDescription: String? {
        switch self {
        case .readOnly: "Read-only mode is on: nothing is sent to the server."
        case .notReady: "Not ready yet."
        }
    }
}

enum ErrorText {
    /// A line for the screen. Never includes request bodies or tokens (APIError carries neither).
    static func describe(_ error: Error) -> String {
        if let error = error as? APIError {
            if case .http(_, let body, _) = error, let keys = body?.keys, !keys.isEmpty {
                return "\(error.localizedDescription) [keys: \(keys.joined(separator: ","))]"
            }
            return error.localizedDescription
        }
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: type(of: error))
    }
}

enum RaftDate {
    // ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}

/// Coalesces repeated requests for the same work: the first `schedule` runs `action` after
/// `delay`; calls made while it waits are merged into that run. Unlike a trailing debounce it
/// still fires under a steady stream of calls (a busy channel). A zero delay runs on the next
/// main-actor turn.
@MainActor
final class Coalescer {
    var delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    var isPending: Bool { task != nil }

    func schedule(_ action: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        let delay = delay
        task = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

extension Message {
    /// The message mentions this user directly.
    func mentionsUser(_ userId: String) -> Bool {
        mentions.contains { $0.type == "user" && $0.id == userId }
    }

    /// A reply in a thread (its channel is the thread's channel).
    var isThreadReply: Bool { conversationContext?.channelType == "thread" }

    var createdDate: Date? { RaftDate.parse(createdAt) }
}

/// `work`'s value or error, for `async let` fan-outs where each part may fail alone.
func captureResult<T: Sendable>(_ work: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await work()) } catch { return .failure(error) }
}
