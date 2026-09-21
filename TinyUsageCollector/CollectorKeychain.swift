import Foundation
import Security

struct CollectorKeychain: Sendable {
    private let service = (Bundle.main.object(forInfoDictionaryKey: "TinyUsageKeychainNamespace") as? String) ?? "dev.tinyusage.TinyUsage.Collector"
    private let legacyService = "com.nicolascharvoz.TinyUsageCollector.credentials"

    func save(_ value: String, account: String) throws {
        try delete(account: account)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8)
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    }

    func load(account: String) -> String? {
        load(service: service, account: account) ?? load(service: legacyService, account: account)
    }

    func loadExternal(service externalService: String) -> String? {
        load(service: externalService, account: nil)
    }

    private func load(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        for candidate in [service, legacyService] {
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: candidate, kSecAttrAccount as String: account] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
