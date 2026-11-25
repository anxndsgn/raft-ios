import Foundation
import Network

/// Watches the device's network path. `onRestore` runs when it comes back after being lost, so
/// the socket reconnects at once instead of waiting out its backoff (up to 30 s).
@MainActor
final class NetworkMonitor {
    var onRestore: (() -> Void)?
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.update(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "raft.network-monitor"))
    }

    func update(satisfied: Bool) {
        defer { wasSatisfied = satisfied }
        if satisfied && !wasSatisfied { onRestore?() }
    }
}

#if DEBUG
/// DEBUG builds only: cuts the app off the network for a while, as airplane mode would. HTTP
/// requests fail with "offline" and the socket cannot connect; the live socket is dropped when
/// it starts, and its end runs the same path as the network coming back (`NetworkMonitor`).
/// The Simulator's network cannot be switched off from a script, so the receive test uses this.
enum SimulatedOutage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var until: Date?

    static var isActive: Bool {
        lock.withLock { until.map { $0 > Date() } ?? false }
    }

    static func begin(seconds: Double) {
        lock.withLock { until = Date().addingTimeInterval(seconds) }
    }

    static var offlineError: URLError { URLError(.notConnectedToInternet) }
}

/// The socket while `SimulatedOutage` is on: fails like a connect with no network.
final class OfflineWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    func send(_ text: String) async throws { throw SimulatedOutage.offlineError }

    func receive() async throws -> String {
        try await Task.sleep(for: .milliseconds(50))
        throw SimulatedOutage.offlineError
    }

    func close() {}
}
#endif
