import Foundation

/// The signed-in person (`auth/me`, the `user` of a login answer). Decoded leniently: only `id`
/// is required; a missing or mistyped optional field is nil rather than a failed sign-in.
struct AuthUser: Sendable, Hashable, Codable, Identifiable {
    var id: String
    var email: String?
    var name: String?
    var displayName: String?
    var description: String?
    var avatarUrl: String?
    var emailVerified: Bool?
    /// Blank or absent: the person has not finished profile setup yet.
    var profileSetupCompletedAt: String?
    var preferredTimezone: String?
    var timeFormat: String?

    init(
        id: String, email: String? = nil, name: String? = nil, displayName: String? = nil,
        description: String? = nil, avatarUrl: String? = nil, emailVerified: Bool? = nil,
        profileSetupCompletedAt: String? = nil, preferredTimezone: String? = nil, timeFormat: String? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.displayName = displayName
        self.description = description
        self.avatarUrl = avatarUrl
        self.emailVerified = emailVerified
        self.profileSetupCompletedAt = profileSetupCompletedAt
        self.preferredTimezone = preferredTimezone
        self.timeFormat = timeFormat
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, name, displayName, description, avatarUrl, emailVerified, profileSetupCompletedAt
        case preferredTimezone, timeFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lenient(.id, as: String.self), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "user id"))
        }
        self.id = id
        email = container.lenient(.email)
        name = container.lenient(.name)
        displayName = container.lenient(.displayName)
        description = container.lenient(.description)
        avatarUrl = container.lenient(.avatarUrl)
        emailVerified = container.lenient(.emailVerified)
        profileSetupCompletedAt = container.lenient(.profileSetupCompletedAt)
        preferredTimezone = container.lenient(.preferredTimezone)
        timeFormat = container.lenient(.timeFormat)
    }

    /// Display name, then name, then email.
    var visibleName: String {
        [displayName, name, email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? id
    }

    /// The old app's rule: setup is needed while `profileSetupCompletedAt` is blank.
    var needsProfileSetup: Bool {
        profileSetupCompletedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

/// A server (workspace) the person belongs to (`GET servers`, a bare array).
struct AuthServer: Sendable, Hashable, Codable, Identifiable {
    var id: String
    var name: String
    var slug: String?
    var ownerId: String?
    var plan: String?
    var role: String?
    var avatarUrl: String?
    var hideHumansFromMembers: Bool
    var createdAt: String?
    var onboardingAgentId: String?

    /// The name as shown (Home, search hints, Settings, the switcher): typed apostrophes become
    /// typographic ones, "xin's team" → "xin’s team", the same wherever it appears.
    var displayName: String { name.replacingOccurrences(of: "'", with: "\u{2019}") }

    init(
        id: String, name: String, slug: String? = nil, ownerId: String? = nil, plan: String? = nil,
        role: String? = nil, avatarUrl: String? = nil, hideHumansFromMembers: Bool = false,
        createdAt: String? = nil, onboardingAgentId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.ownerId = ownerId
        self.plan = plan
        self.role = role
        self.avatarUrl = avatarUrl
        self.hideHumansFromMembers = hideHumansFromMembers
        self.createdAt = createdAt
        self.onboardingAgentId = onboardingAgentId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, ownerId, plan, role, avatarUrl, hideHumansFromMembers, createdAt, onboardingAgentId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lenient(.id, as: String.self), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "server id"))
        }
        self.id = id
        name = container.lenient(.name) ?? ""
        slug = container.lenient(.slug)
        ownerId = container.lenient(.ownerId)
        plan = container.lenient(.plan)
        role = container.lenient(.role)
        avatarUrl = container.lenient(.avatarUrl)
        hideHumansFromMembers = container.lenient(.hideHumansFromMembers) ?? false
        createdAt = container.lenient(.createdAt)
        onboardingAgentId = container.lenient(.onboardingAgentId)
    }
}

/// An access/refresh token pair. `description` never shows the tokens.
struct TokenPair: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var accessToken: String
    var refreshToken: String

    var description: String { "TokenPair(redacted)" }
    var debugDescription: String { description }
}

/// Everything kept for a signed-in person, per environment, in the Keychain.
struct StoredSession: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var user: AuthUser
    var tokens: TokenPair
    var servers: [AuthServer]
    var selectedServerId: String?
    var signedInAt: Date

    var selectedServer: AuthServer? { servers.first { $0.id == selectedServerId } }

    var description: String {
        "StoredSession(user: \(user.id), servers: \(servers.count), selected: \(selectedServerId ?? "none"))"
    }

    var debugDescription: String { description }

    /// The selection to keep after the server list changed: the current one if still listed,
    /// else the first server, else none.
    static func resolveSelection(current: String?, servers: [AuthServer]) -> String? {
        if let current, servers.contains(where: { $0.id == current }) { return current }
        return servers.first?.id
    }
}

/// Keychain layout: one session per environment plus one installation id for the app.
struct SessionVault: Sendable {
    let secure: any SecureStore

    static func sessionKey(_ environment: RaftEnvironment.Kind) -> String { "session.\(environment.rawValue)" }
    static let installationKey = "installation-id"

    func load(_ environment: RaftEnvironment.Kind) -> StoredSession? {
        guard let data = try? secure.data(for: Self.sessionKey(environment)) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(_ session: StoredSession, environment: RaftEnvironment.Kind) throws {
        try secure.set(try JSONEncoder().encode(session), for: Self.sessionKey(environment))
    }

    func clear(_ environment: RaftEnvironment.Kind) {
        try? secure.remove(Self.sessionKey(environment))
    }

    /// `ari_<32 hex>`, created once and kept (sent with every refresh so the server can tell
    /// this install's refresh attempts apart).
    func installationId() -> String {
        if let data = try? secure.data(for: Self.installationKey),
           let value = String(data: data, encoding: .utf8), InstallationId.isValid(value) {
            return value
        }
        let value = InstallationId.generate()
        try? secure.set(Data(value.utf8), for: Self.installationKey)
        return value
    }
}

enum InstallationId {
    static func generate() -> String { "ari_\(RandomHex.string(bytes: 16))" }

    static func isValid(_ value: String) -> Bool {
        value.hasPrefix("ari_") && value.count == 36 && value.dropFirst(4).allSatisfy(\.isHexDigit)
    }
}

enum RefreshAttemptId {
    static func generate() -> String { "arf_\(RandomHex.string(bytes: 8))" }

    static func isValid(_ value: String) -> Bool {
        value.hasPrefix("arf_") && value.count == 20 && value.dropFirst(4).allSatisfy(\.isHexDigit)
    }
}
