import Foundation

/// The error envelope Raft routes answer with: `{ error, code, message?, retryable?, ... }`
/// (server `routes/errorResponse.ts`). Every field is optional and leniently decoded; `code` may
/// be a non-string on some routes and is then dropped rather than failing the decode.
struct ServerErrorBody: Sendable, Hashable, Decodable {
    var error: String?
    var message: String?
    var code: String?
    var retryable: Bool?
    /// `second_factor_step_up_required`: the methods the person can answer with.
    var methods: [String]?
    /// `second_factor_locked`: ISO time the lock ends.
    var lockedUntil: String?
    /// Top-level keys of the body (names only, never values) for diagnostics.
    var keys: [String]

    private enum CodingKeys: String, CodingKey {
        case error, message, code, retryable, methods, lockedUntil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = container.lenient(.error)
        message = container.lenient(.message)
        code = container.lenient(.code)
        retryable = container.lenient(.retryable)
        methods = container.lenient(.methods)
        lockedUntil = container.lenient(.lockedUntil)
        let any = try decoder.container(keyedBy: AnyCodingKey.self)
        keys = any.allKeys.map(\.stringValue).sorted()
    }

    static func parse(_ data: Data) -> ServerErrorBody? {
        guard !data.isEmpty else { return nil }
        return try? RaftJSON.decode(ServerErrorBody.self, from: data)
    }

    /// The person-readable sentence the server sent, if any.
    var displayMessage: String? {
        [error, message].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

enum APIError: Error, Sendable, Equatable {
    /// No response (offline, DNS, TLS, timeout). The payload is URLError's description.
    case transport(String)
    /// A non-2xx answer.
    case http(status: Int, body: ServerErrorBody?, traceId: String?)
    /// A 2xx answer whose body did not match the expected shape.
    case decoding(path: String, detail: String, traceId: String?)
    /// The refresh token was rejected (or a retried request answered 401 again): sign in again.
    case sessionExpired
    /// The call needs a session and there is none.
    case notSignedIn
    /// The server needs the second factor before this call can proceed.
    case secondFactorRequired(SecondFactorChallenge)

    var status: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }

    var serverCode: String? {
        if case .http(_, let body, _) = self { return body?.code }
        return nil
    }
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .transport(let detail):
            return "Network error: \(detail)"
        case .http(let status, let body, let traceId):
            var text = "HTTP \(status)"
            if let code = body?.code { text += " \(code)" }
            if let message = body?.displayMessage { text += ": \(message)" }
            if let traceId { text += " (trace \(traceId))" }
            return text
        case .decoding(let path, let detail, _):
            return "Unexpected response from \(path): \(detail)"
        case .sessionExpired:
            return "Your session expired. Sign in again."
        case .notSignedIn:
            return "Not signed in."
        case .secondFactorRequired:
            return "Two-step verification required."
        }
    }
}
