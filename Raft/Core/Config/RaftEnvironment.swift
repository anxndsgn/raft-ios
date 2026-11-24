import Foundation

/// A Raft deployment the app talks to.
struct RaftEnvironment: Sendable, Hashable, Codable, Identifiable {
    enum Kind: String, Sendable, Codable, CaseIterable {
        case production
        case staging
    }

    let kind: Kind
    /// REST base, ending in `/api/`; every API path is relative to it.
    let apiBaseURL: URL
    /// Socket.IO origin (`/socket.io/` is appended by the realtime client).
    let socketBaseURL: URL
    let webURL: URL

    var id: String { kind.rawValue }

    var displayName: String {
        switch kind {
        case .production: "Production"
        case .staging: "Staging"
        }
    }

    static let production = RaftEnvironment(
        kind: .production,
        apiBaseURL: URL(string: "https://api.raft.build/api/")!,
        socketBaseURL: URL(string: "https://api.raft.build")!,
        webURL: URL(string: "https://app.raft.build")!
    )

    static let staging = RaftEnvironment(
        kind: .staging,
        apiBaseURL: URL(string: "https://api-aws-staging.botiverse.dev/api/")!,
        socketBaseURL: URL(string: "https://api-aws-staging.botiverse.dev")!,
        webURL: URL(string: "https://raft-app-staging.botiverse.dev")!
    )

    static func of(_ kind: Kind) -> RaftEnvironment {
        switch kind {
        case .production: .production
        case .staging: .staging
        }
    }

    /// `apiBaseURL` + a relative path (`channels/dm`), with query items.
    func apiURL(path: String, query: [URLQueryItem] = []) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = URL(string: trimmed, relativeTo: apiBaseURL)?.absoluteURL ?? apiBaseURL.appendingPathComponent(trimmed)
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + query
        // `+` is legal in a query but servers read it as a space; encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url
    }
}

/// The hidden environment switch. Only the choice is stored (UserDefaults); sessions are kept
/// per environment in the Keychain, so switching never mixes tokens across deployments.
final class EnvironmentStore: @unchecked Sendable {
    // @unchecked: UserDefaults is thread-safe; the only state is the defaults instance.
    private let defaults: UserDefaults
    private static let key = "raft.environment"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var current: RaftEnvironment {
        let kind = defaults.string(forKey: Self.key).flatMap(RaftEnvironment.Kind.init(rawValue:)) ?? .production
        return .of(kind)
    }

    func set(_ kind: RaftEnvironment.Kind) {
        defaults.set(kind.rawValue, forKey: Self.key)
    }
}
