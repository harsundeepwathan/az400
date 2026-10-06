import Foundation
import Security
import VectorCore

/// Session tokens in the Keychain: this device only, available after first
/// unlock (so background refreshes work), never in backups or iCloud.
final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service = "app.vector.session"
    private let account = "tokens"
    private let lock = NSLock()

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> AuthTokens? {
        lock.withLock {
            var item: CFTypeRef?
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(AuthTokens.self, from: data)
        }
    }

    func save(_ tokens: AuthTokens?) {
        lock.withLock {
            SecItemDelete(query as CFDictionary)
            guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

/// Events waiting to upload, kept in Application Support so they survive relaunches.
enum EventQueueFile {
    static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("pending-events.json")
    }

    static func load() -> [AnalyticsEvent] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AnalyticsEvent].self, from: data)) ?? []
    }

    static func save(_ events: [AnalyticsEvent]) {
        guard let url else { return }
        if events.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

/// The analytics preference, readable from any thread (the event queue checks it).
enum AnalyticsPreference {
    static let key = "analyticsEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
