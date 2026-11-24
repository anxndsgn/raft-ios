import Foundation

/// Reconnect backoff: 1 s doubling to 30 s, ±50 % jitter, never under 0.5 s.
struct ReconnectPolicy: Sendable, Hashable {
    var base: Double = 1
    var cap: Double = 30
    var jitter: Double = 0.5
    var floor: Double = 0.5

    /// The wait after `failures` consecutive failed attempts (1 = the first failure).
    /// `random` is uniform in 0...1 (0.5 = no jitter).
    func delay(failures: Int, random: Double) -> Double {
        let exponent = Double(max(0, failures - 1))
        let raw = min(cap, base * pow(2, min(exponent, 30)))
        let factor = 1 + jitter * (2 * min(max(random, 0), 1) - 1)
        return min(cap, max(floor, raw * factor))
    }

    func delay(failures: Int) -> Double {
        delay(failures: failures, random: Double.random(in: 0...1))
    }
}
