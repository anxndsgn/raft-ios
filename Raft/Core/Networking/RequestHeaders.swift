import Foundation

enum HeaderName {
    static let authorization = "Authorization"
    static let serverId = "X-Server-Id"
    static let userAgent = "User-Agent"
    static let clientPlatform = "X-Raft-Client-Platform"
    static let clientVersion = "X-Raft-Client-Version"
    static let traceparent = "traceparent"
    static let requestId = "x-request-id"
    static let refreshAttemptId = "X-Slock-Auth-Refresh-Attempt-Id"
    static let installationId = "X-Slock-Auth-Installation-Id"
    static let retryAfter = "Retry-After"
    static let traceId = "X-Trace-Id"
}

/// A W3C trace id (32 hex) and span id (16 hex), neither all zero.
struct TraceIds: Sendable, Hashable {
    let traceId: String
    let spanId: String

    var traceparent: String { "00-\(traceId)-\(spanId)-01" }

    static func random() -> TraceIds {
        TraceIds(traceId: RandomHex.nonZero(bytes: 16), spanId: RandomHex.nonZero(bytes: 8))
    }
}

enum RandomHex {
    static func string(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    static func nonZero(bytes count: Int) -> String {
        while true {
            let value = string(bytes: count)
            if value.contains(where: { $0 != "0" }) { return value }
        }
    }
}

/// The header set every Raft API request carries (inventory §1; old app
/// `RaftHttpRequestSemantics.kt` / `AuthTransport.kt`). Pure, so it is unit tested.
enum RequestHeaders {
    static func build(
        appInfo: AppInfo,
        accessToken: String?,
        serverId: String?,
        trace: TraceIds = .random(),
        extra: [String: String] = [:]
    ) -> [String: String] {
        var headers: [String: String] = [
            HeaderName.userAgent: appInfo.userAgent,
            HeaderName.clientPlatform: "ios",
            HeaderName.clientVersion: appInfo.version,
            HeaderName.traceparent: trace.traceparent,
            HeaderName.requestId: "mobile-\(trace.traceId)",
            "Accept": "application/json",
        ]
        if let accessToken, !accessToken.isEmpty {
            headers[HeaderName.authorization] = "Bearer \(accessToken)"
        }
        if let serverId, !serverId.isEmpty {
            headers[HeaderName.serverId] = serverId
        }
        for (name, value) in extra {
            // A caller's own value wins over a default with the same (case-insensitive) name.
            if let existing = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                headers.removeValue(forKey: existing)
            }
            headers[name] = value
        }
        return headers
    }
}
