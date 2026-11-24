import Foundation
import Testing
@testable import Raft

struct PKCEAndTOTPTests {
    @Test func pkceMatchesRFC7636Vector() {
        #expect(PKCEPair.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedPairIsValidAndFresh() {
        let first = PKCEPair.generate()
        let second = PKCEPair.generate()
        #expect(PKCEPair.isValid(first.verifier))
        #expect(first.verifier.count == 43)
        #expect(first.challenge == PKCEPair.challenge(for: first.verifier))
        #expect(!first.challenge.contains("="))
        #expect(first.verifier != second.verifier)
        #expect(!PKCEPair.isValid("short"))
        #expect(!PKCEPair.isValid(String(repeating: "a", count: 42) + "!"))
    }

    @Test func callbackParsing() throws {
        let ok = try #require(AppLoginCallback.parse(URL(string: "raft-debug://login/callback?requestId=r1&code=c1")!, expectedScheme: "raft-debug"))
        #expect(ok.requestId == "r1")
        #expect(ok.code == "c1")
        let denied = try #require(AppLoginCallback.parse(URL(string: "raft://login/callback?requestId=r1&error=access_denied")!, expectedScheme: "raft"))
        #expect(denied.error == "access_denied")
        #expect(AppLoginCallback.parse(URL(string: "raft://login/callback?code=c")!, expectedScheme: "raft-debug") == nil, "wrong scheme")
        #expect(AppLoginCallback.parse(URL(string: "raft://other/callback?code=c")!, expectedScheme: "raft") == nil, "wrong host")
        #expect(AppLoginCallback.parse(URL(string: "raft://login/callback?requestId=r")!, expectedScheme: "raft") == nil, "no code or error")
    }

    #if DEBUG
    /// RFC 6238 appendix B (SHA-1 seed "12345678901234567890").
    @Test(arguments: [
        (59.0, "94287082"),
        (1111111109.0, "07081804"),
        (1111111111.0, "14050471"),
        (1234567890.0, "89005924"),
        (2000000000.0, "69279037"),
        (20000000000.0, "65353130"),
    ])
    func totpMatchesRFC6238(time: Double, expected: String) {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        #expect(DebugTOTP.code(secretBase32: secret, at: Date(timeIntervalSince1970: time), digits: 8) == expected)
        #expect(DebugTOTP.code(secretBase32: secret, at: Date(timeIntervalSince1970: time)) == String(expected.suffix(6)))
    }

    @Test func base32IsLenient() {
        #expect(Base32.decode("gezd gnbv-gy3t qojq====") == Data("1234567890".utf8))
        #expect(Base32.decode("GEZ1") == nil, "1 is not base32")
        #expect(DebugTOTP.code(secretBase32: "not base32!") == nil)
        #expect(DebugTOTP.code(secretBase32: "") == nil)
        let remaining = DebugTOTP.secondsRemaining(at: Date(timeIntervalSince1970: 59))
        #expect(remaining == 1)
    }
    #endif

    @Test func secondFactorAnswersValidateAndEncode() throws {
        #expect(SecondFactorAnswer.totp("123 456").isWellFormed)
        #expect(!SecondFactorAnswer.totp("12345").isWellFormed)
        #expect(!SecondFactorAnswer.totp("12345a").isWellFormed)
        #expect(SecondFactorAnswer.backupCode(" abcd-efgh ").isWellFormed)
        #expect(!SecondFactorAnswer.backupCode("  ").isWellFormed)
        let totp = try #require(JSONValue.parse(try RaftJSON.encode(SecondFactorStepUpBody(.totp("123 456")))))
        #expect(totp == ["code": "123456"])
        let backup = try #require(JSONValue.parse(try RaftJSON.encode(SecondFactorStepUpBody(.backupCode(" abcd-efgh ")))))
        #expect(backup == ["backupCode": "abcd-efgh"])
    }

    @Test func secondFactorResultsParse() {
        func parse(_ status: Int, _ body: String) -> SecondFactorResult {
            SecondFactorResult.parse(status: status, data: Data(body.utf8))
        }
        #expect(parse(200, #"{"verified":true,"backupCodesRemaining":7}"#) == .verified(backupCodesRemaining: 7))
        #expect(parse(200, #"{"verified":false}"#) == .failed(status: 200, code: "second_factor_step_up_contract_mismatch", message: nil))
        #expect(parse(400, #"{"error":"Invalid code","code":"second_factor_code_invalid"}"#) == .codeInvalid)
        #expect(parse(400, #"{"code":"backup_code_used"}"#) == .backupCodeUsed)
        #expect(parse(409, #"{"code":"second_factor_not_enabled"}"#) == .notEnabled)
        #expect(parse(403, #"{"code":"session_family_required"}"#) == .sessionFamilyRequired)
        if case .locked(let until) = parse(429, #"{"code":"second_factor_locked","lockedUntil":"2026-11-24T10:00:00.000Z"}"#) {
            #expect(until == ISO8601.parse("2026-11-24T10:00:00Z"))
        } else { Issue.record("locked") }
        #expect(parse(500, "oops") == .failed(status: 500, code: nil, message: nil))
    }

    @Test func challengeAndStatusMethods() throws {
        let body = try #require(ServerErrorBody.parse(Data(#"{"error":"Verify","code":"second_factor_step_up_required","methods":["passkey","backup_code","totp","sms"]}"#.utf8)))
        let challenge = try #require(SecondFactorChallenge.parse(status: 403, body: body, path: "servers"))
        #expect(challenge.methodNames == ["passkey", "backup_code", "totp", "sms"])
        #expect(challenge.usableMethods == [.totp, .backupCode])
        #expect(!challenge.passkeyOnly)
        #expect(SecondFactorChallenge.parse(status: 401, body: body, path: "servers") == nil)
        let passkeyOnly = SecondFactorPrompt(stage: .credentials(email: "e", password: "p", challenge: nil), methods: [.passkey], serverMessage: nil, refusedCall: "x")
        #expect(passkeyOnly.passkeyOnly)
        #expect(passkeyOnly.usableMethods.isEmpty)
        #expect(!passkeyOnly.description.contains("p,"), "no secrets in descriptions")
        let unknown = SecondFactorPrompt(stage: .credentials(email: "e", password: "p", challenge: nil), methods: [], serverMessage: nil, refusedCall: "x")
        #expect(unknown.usableMethods == [.totp, .backupCode], "no list: offer both")

        let status = try RaftJSON.decode(SecondFactorStatus.self, from: Data(#"{"enabled":true,"methods":{"totp":true,"passkeys":"2","backupCodesRemaining":0},"sessionVerified":false}"#.utf8))
        #expect(status.availableMethods == [.totp, .passkey])
    }
}
