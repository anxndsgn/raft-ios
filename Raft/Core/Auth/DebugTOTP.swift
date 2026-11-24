#if DEBUG
import CryptoKit
import Foundation

/// DEBUG-only TOTP generator (RFC 6238: HMAC-SHA1, 30 s step, 6 digits) so a test account's
/// authenticator secret can produce codes during development. Never log the secret or the code.
/// Compiled out of Release builds.
enum DebugTOTP {
    /// The code for `secret` (base32, case-insensitive, spaces/dashes/padding ignored) at `date`.
    static func code(secretBase32: String, at date: Date = Date(), period: TimeInterval = 30, digits: Int = 6) -> String? {
        guard let key = Base32.decode(secretBase32), !key.isEmpty, period > 0, (6...8).contains(digits) else { return nil }
        let counter = UInt64(floor(date.timeIntervalSince1970 / period))
        return code(key: key, counter: counter, digits: digits)
    }

    /// HOTP (RFC 4226) with HMAC-SHA1.
    static func code(key: Data, counter: UInt64, digits: Int = 6) -> String {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = binary % modulus
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// Seconds until the current code changes.
    static func secondsRemaining(at date: Date = Date(), period: TimeInterval = 30) -> Int {
        Int(period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period))
    }
}

enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// RFC 4648 base32. Nil for any character outside the alphabet.
    static func decode(_ text: String) -> Data? {
        let cleaned = text.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
        var buffer: UInt64 = 0
        var bits = 0
        var bytes: [UInt8] = []
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt64(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
        }
        return Data(bytes)
    }
}
#endif
