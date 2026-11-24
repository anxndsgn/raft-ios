import Foundation
import Security

/// Small secret blobs by key. The app uses the Keychain; tests use `InMemorySecureStore`.
protocol SecureStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

struct KeychainError: Error, Equatable, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String { "Keychain \(operation) failed (\(status))" }
}

/// Generic-password items under one service, readable after first unlock (so background refresh
/// and realtime reconnects work), never synced to iCloud or restored to another device.
struct KeychainStore: SecureStore {
    let service: String

    init(service: String = "com.xinan.raft.session") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func data(for key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status, operation: "read")
        }
    }

    func set(_ data: Data, for key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key)
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added, operation: "add") }
        } else if status != errSecSuccess {
            throw KeychainError(status: status, operation: "update")
        }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    /// Keychain items outlive an uninstall, so a reinstall would come back already signed in
    /// with the previous install's tokens. UserDefaults do not survive one: the first launch
    /// without the marker drops everything under this service.
    func clearIfFreshInstall(defaults: UserDefaults = .standard) {
        let marker = "raft.installed"
        guard !defaults.bool(forKey: marker) else { return }
        let all: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(all as CFDictionary)
        defaults.set(true, forKey: marker)
    }
}

final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init(_ items: [String: Data] = [:]) {
        self.items = items
    }

    func data(for key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    func set(_ data: Data, for key: String) throws {
        lock.withLock { items[key] = data }
    }

    func remove(_ key: String) throws {
        _ = lock.withLock { items.removeValue(forKey: key) }
    }

    var keys: [String] { lock.withLock { Array(items.keys).sorted() } }
}
