import CryptoKit
import Foundation

/// PKCE (RFC 7636) for the browser app-login: a 43–128 char verifier from `[A-Za-z0-9_-]` and its
/// S256 challenge `BASE64URL(SHA256(ASCII(verifier)))` without padding (old app
/// `RaftIosMobileOAuthHost.swift`; the server checks `^[A-Za-z0-9_-]{43,128}$`).
struct PKCEPair: Sendable, Hashable {
    let verifier: String
    let challenge: String

    static func generate() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        let verifier = Base64URL.encode(Data(bytes))
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func isValid(_ value: String) -> Bool {
        (43...128).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `raft://login/callback?requestId=…&code=…` (or `&error=…`), strictly parsed.
struct AppLoginCallback: Sendable, Hashable {
    let requestId: String?
    let code: String?
    let error: String?

    static func parse(_ url: URL, expectedScheme: String) -> AppLoginCallback? {
        guard url.scheme?.lowercased() == expectedScheme.lowercased(),
              url.host?.lowercased() == "login",
              url.path == "/callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let callback = AppLoginCallback(requestId: value("requestId"), code: value("code"), error: value("error"))
        guard callback.code != nil || callback.error != nil else { return nil }
        return callback
    }
}
