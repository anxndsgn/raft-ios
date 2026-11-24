import Foundation

/// Two-step verification ("second factor") contract, from the old app's
/// `SecondFactorStepUpApi.kt` / `AccountLoginSecurityApi.kt` (server
/// `routes/secondFactor.ts`, `services/secondFactor/*`):
///
/// - A refused call answers `403 { error, code: "second_factor_step_up_required", methods: [...] }`
///   with methods from `totp | passkey | backup_code`.
/// - `POST auth/second-factor/step-up` with `{ code }` (authenticator) or `{ backupCode }` answers
///   `{ verified: true, backupCodesRemaining? }`; refusals are `{ error, code, ...extra }`:
///   400 `second_factor_code_invalid`, 400 `backup_code_used`, 429 `second_factor_locked`
///   (`lockedUntil`), 409 `second_factor_not_enabled`, 403 `session_family_required`.
/// - `GET auth/second-factor/status` → `{ enabled, methods: { totp, passkeys, backupCodesRemaining },
///   sessionVerified, recovery }`; the router answers 404 while the feature flag is off.
enum SecondFactorMethod: String, Sendable, Hashable, CaseIterable {
    case totp
    case backupCode = "backup_code"
    case passkey

    var displayName: String {
        switch self {
        case .totp: "Authenticator code"
        case .backupCode: "Backup code"
        case .passkey: "Passkey"
        }
    }

    /// Methods the app can answer with today, in the order it offers them.
    static let supportedInApp: [SecondFactorMethod] = [.totp, .backupCode]
}

struct SecondFactorChallenge: Sendable, Hashable {
    static let requiredCode = "second_factor_step_up_required"

    /// The method names the server listed, as sent (unknown names kept).
    var methodNames: [String]
    var serverMessage: String?
    /// The API path whose call was refused.
    var path: String

    var methods: [SecondFactorMethod] { methodNames.compactMap(SecondFactorMethod.init(rawValue:)) }

    /// The listed methods the app can answer, authenticator code first.
    var usableMethods: [SecondFactorMethod] { SecondFactorMethod.supportedInApp.filter { methods.contains($0) } }

    /// Only a passkey (or nothing usable) was listed: the app cannot complete the step here.
    var passkeyOnly: Bool { usableMethods.isEmpty && methods.contains(.passkey) }

    /// The challenge of a `403 second_factor_step_up_required`; nil for anything else.
    static func parse(status: Int, body: ServerErrorBody?, path: String) -> SecondFactorChallenge? {
        guard status == 403, let body, body.code == requiredCode else { return nil }
        return SecondFactorChallenge(methodNames: body.methods ?? [], serverMessage: body.displayMessage, path: path)
    }
}

enum SecondFactorAnswer: Sendable, Hashable {
    case totp(String)
    case backupCode(String)

    var method: SecondFactorMethod {
        switch self {
        case .totp: .totp
        case .backupCode: .backupCode
        }
    }

    /// Normalized code: authenticator codes lose spaces; backup codes are trimmed only.
    var normalizedCode: String {
        switch self {
        case .totp(let code): code.filter { !$0.isWhitespace }
        case .backupCode(let code): code.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// `POST auth/second-factor/step-up` body: exactly one of `code` / `backupCode`.
struct SecondFactorStepUpBody: Encodable, Sendable, Hashable {
    let code: String?
    let backupCode: String?

    init(_ answer: SecondFactorAnswer) {
        switch answer {
        case .totp: code = answer.normalizedCode; backupCode = nil
        case .backupCode: code = nil; backupCode = answer.normalizedCode
        }
    }

    private enum CodingKeys: String, CodingKey { case code, backupCode }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(backupCode, forKey: .backupCode)
    }
}

enum SecondFactorResult: Sendable, Hashable {
    case verified(backupCodesRemaining: Int?)
    case codeInvalid
    case backupCodeUsed
    case locked(until: Date?)
    /// Turned off meanwhile: just retry the refused request.
    case notEnabled
    /// This sign-in cannot be verified: sign in again.
    case sessionFamilyRequired
    /// The sign-in challenge is used, expired, or its password changed: sign in again.
    case challengeExpired
    /// Too many wrong answers for this sign-in challenge: sign in again.
    case attemptsExhausted
    case failed(status: Int, code: String?, message: String?)

    /// The prompt can't be answered again: start the sign-in over.
    var endsSignIn: Bool {
        switch self {
        case .sessionFamilyRequired, .challengeExpired, .attemptsExhausted: true
        default: false
        }
    }

    static func parse(status: Int, data: Data) -> SecondFactorResult {
        if (200..<300).contains(status) {
            let json = JSONValue.parse(data)
            if json?["verified"]?.boolValue == true {
                return .verified(backupCodesRemaining: json?["backupCodesRemaining"]?.int64Value.flatMap { Int(exactly: $0) })
            }
            return .failed(status: status, code: "second_factor_step_up_contract_mismatch", message: nil)
        }
        let body = ServerErrorBody.parse(data)
        switch body?.code {
        case "second_factor_code_invalid": return .codeInvalid
        case "backup_code_used": return .backupCodeUsed
        case "second_factor_locked":
            return .locked(until: body?.lockedUntil.flatMap { ISO8601.parse($0) })
        case "second_factor_not_enabled": return .notEnabled
        case "session_family_required": return .sessionFamilyRequired
        case "challenge_expired": return .challengeExpired
        case "challenge_attempts_exhausted": return .attemptsExhausted
        default: return .failed(status: status, code: body?.code, message: body?.displayMessage)
        }
    }

    var displayMessage: String {
        switch self {
        case .verified: "Verified."
        case .codeInvalid: "That code isn't right. Check it and try again."
        case .backupCodeUsed: "That backup code was already used. Use another one."
        case .locked(let until):
            if let until { "Too many attempts. Try again after \(until.formatted(date: .omitted, time: .shortened))." }
            else { "Too many attempts. Try again later." }
        case .notEnabled: "Two-step verification is off for this account."
        case .sessionFamilyRequired: "This sign-in can't be verified. Sign in again."
        case .challengeExpired: "This sign-in has expired. Sign in again."
        case .attemptsExhausted: "Too many wrong codes for this sign-in. Sign in again."
        case .failed(let status, let code, let message):
            message ?? "Verification failed (HTTP \(status)\(code.map { " \($0)" } ?? ""))."
        }
    }
}

/// `GET auth/second-factor/status` (only the fields the sign-in flow reads).
struct SecondFactorStatus: Sendable, Hashable, Decodable {
    var enabled: Bool
    var totp: Bool
    var passkeys: Int
    var backupCodesRemaining: Int
    var sessionVerified: Bool?

    private enum CodingKeys: String, CodingKey { case enabled, methods, sessionVerified }
    private enum MethodKeys: String, CodingKey { case totp, passkeys, backupCodesRemaining }

    init(enabled: Bool, totp: Bool, passkeys: Int, backupCodesRemaining: Int, sessionVerified: Bool?) {
        self.enabled = enabled
        self.totp = totp
        self.passkeys = passkeys
        self.backupCodesRemaining = backupCodesRemaining
        self.sessionVerified = sessionVerified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.lenient(.enabled) ?? false
        sessionVerified = container.lenient(.sessionVerified)
        let methods = try? container.nestedContainer(keyedBy: MethodKeys.self, forKey: .methods)
        totp = methods?.lenient(.totp) ?? false
        passkeys = methods?.flexibleInt(.passkeys) ?? 0
        backupCodesRemaining = methods?.flexibleInt(.backupCodesRemaining) ?? 0
    }

    /// The methods this account can answer with, as a challenge would list them.
    var availableMethods: [SecondFactorMethod] {
        var result: [SecondFactorMethod] = []
        if totp { result.append(.totp) }
        if backupCodesRemaining > 0 { result.append(.backupCode) }
        if passkeys > 0 { result.append(.passkey) }
        return result
    }
}

enum ISO8601 {
    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
